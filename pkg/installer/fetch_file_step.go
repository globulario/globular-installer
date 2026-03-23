package installer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// FetchFileStep downloads a file over HTTPS, verifies its checksum, and installs it atomically.
type FetchFileStep struct {
	URL    string
	To     string
	Sha256 string
	Mode   fs.FileMode `json:"-"`
	Owner  string
	Group  string
	Binary bool

	parsedURL *url.URL
}

func NewFetchFileStep() *FetchFileStep {
	return &FetchFileStep{}
}

func (s *FetchFileStep) Name() string {
	return "fetch-file"
}

func (s *FetchFileStep) validate() error {
	if s.URL == "" {
		return fmt.Errorf("url is required")
	}
	parsed, err := url.Parse(s.URL)
	if err != nil {
		return fmt.Errorf("invalid url: %w", err)
	}
	if parsed.Scheme != "https" {
		return fmt.Errorf("url scheme %q not allowed (must be https)", parsed.Scheme)
	}
	s.parsedURL = parsed
	if s.To == "" {
		return fmt.Errorf("destination path is required")
	}
	if !filepath.IsAbs(s.To) {
		return fmt.Errorf("destination path %q is not absolute", s.To)
	}
	if len(s.Sha256) != 64 {
		return fmt.Errorf("sha256 must be 64 hex chars")
	}
	if _, err := hex.DecodeString(strings.ToLower(s.Sha256)); err != nil {
		return fmt.Errorf("invalid sha256: %w", err)
	}
	return nil
}

func (s *FetchFileStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if err := s.validate(); err != nil {
		return StatusUnknown, err
	}
	match, err := s.currentMatches()
	if err != nil {
		return StatusUnknown, err
	}
	if match {
		return StatusOK, nil
	}
	return StatusNeedsApply, nil
}

func (s *FetchFileStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if err := s.validate(); err != nil {
		return err
	}
	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: would fetch %s -> %s (sha256 %s)", s.URL, s.To, s.Sha256)
		}
		return nil
	}
	dir := filepath.Dir(s.To)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".fetch-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer tmp.Close()
	defer os.Remove(tmp.Name())

	ctxTimeout, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctxTimeout, http.MethodGet, s.URL, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if req.URL.Scheme != "https" {
				return fmt.Errorf("redirect to non-https url %s", req.URL)
			}
			return nil
		},
		Timeout: 60 * time.Second,
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", s.URL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: unexpected status %s", s.URL, resp.Status)
	}

	hasher := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, hasher), resp.Body); err != nil {
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync temp file: %w", err)
	}

	sum := hex.EncodeToString(hasher.Sum(nil))
	if sum != strings.ToLower(s.Sha256) {
		return fmt.Errorf("sha256 mismatch: got %s expected %s", sum, s.Sha256)
	}

	if s.Mode != 0 {
		if err := os.Chmod(tmp.Name(), fs.FileMode(s.Mode)); err != nil {
			return fmt.Errorf("chmod temp file: %w", err)
		}
	}
	if err := applyOwnership(tmp.Name(), s.Owner, s.Group); err != nil {
		return fmt.Errorf("apply ownership: %w", err)
	}
	if err := os.Rename(tmp.Name(), s.To); err != nil {
		return fmt.Errorf("rename %s: %w", s.To, err)
	}

	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		ctx.Runtime.ChangedFiles[s.To] = true
		if s.Binary {
			ctx.Runtime.ChangedBinaries[s.To] = true
		}
	}
	return nil
}

func (s *FetchFileStep) currentMatches() (bool, error) {
	info, err := os.Stat(s.To)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if s.Mode != 0 && fs.FileMode(s.Mode) != info.Mode().Perm() {
		return false, nil
	}
	if s.Owner != "" || s.Group != "" {
		curUID, curGID, err := statUIDGID(s.To)
		if err != nil {
			return false, err
		}
		expUID, expGID, err := resolveUIDGID(s.Owner, s.Group)
		if err != nil {
			return false, err
		}
		if expUID != -1 && curUID != expUID {
			return false, nil
		}
		if expGID != -1 && curGID != expGID {
			return false, nil
		}
	}
	if s.Sha256 != "" {
		sum, err := computeSHA256(s.To)
		if err != nil {
			return false, err
		}
		if !strings.EqualFold(sum, s.Sha256) {
			return false, nil
		}
	}
	return true, nil
}

func computeSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func applyOwnership(path, owner, group string) error {
	if owner == "" && group == "" {
		return nil
	}
	expUID, expGID, err := resolveUIDGID(owner, group)
	if err != nil {
		return err
	}
	curUID, curGID, err := statUIDGID(path)
	if err != nil {
		return err
	}
	if expUID == -1 {
		expUID = curUID
	}
	if expGID == -1 {
		expGID = curGID
	}
	return os.Chown(path, expUID, expGID)
}

func statUIDGID(path string) (int, int, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, fmt.Errorf("unsupported stat type for %s", path)
	}
	return int(stat.Uid), int(stat.Gid), nil
}

func resolveUIDGID(owner, group string) (int, int, error) {
	uid, gid := -1, -1
	if owner != "" {
		u, err := user.Lookup(owner)
		if err != nil {
			return -1, -1, fmt.Errorf("lookup user %s: %w", owner, err)
		}
		parsed, err := strconv.Atoi(u.Uid)
		if err != nil {
			return -1, -1, fmt.Errorf("parse uid for %s: %w", owner, err)
		}
		uid = parsed
	}
	if group != "" {
		g, err := user.LookupGroup(group)
		if err != nil {
			return -1, -1, fmt.Errorf("lookup group %s: %w", group, err)
		}
		parsed, err := strconv.Atoi(g.Gid)
		if err != nil {
			return -1, -1, fmt.Errorf("parse gid for %s: %w", group, err)
		}
		gid = parsed
	}
	return uid, gid, nil
}
