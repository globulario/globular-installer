package installer

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// StagePackageStep extracts a package into a staging directory and validates its manifest.
type StagePackageStep struct {
	Path                 string
	VerifySHA256         string
	CacheDir             string
	StagingRoot          string
	RequirePlatformMatch bool
	// RequireTypeService rejects packages whose package.json "type" is not "service".
	// Set to false for infrastructure packages (type="infrastructure") and command
	// packages (type="command"). Defaults to true for backwards compatibility.
	RequireTypeService bool
}

func (s *StagePackageStep) Name() string { return "stage-package" }

func (s *StagePackageStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.StagingDir != "" {
		if hasPackageJSON(ctx.StagingDir) {
			return StatusOK, nil
		}
	}

	pkgPath := s.Path
	if pkgPath == "" {
		return StatusUnknown, fmt.Errorf("path is required")
	}
	pkgPath = filepath.Clean(pkgPath)
	digest, err := fileSHA256(pkgPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return StatusNeedsApply, nil
		}
		return StatusUnknown, err
	}
	stagingDir := s.stagingDir(digest)
	if hasPackageJSON(stagingDir) {
		ctx.StagingDir = stagingDir
		return StatusOK, nil
	}
	return StatusNeedsApply, nil
}

func (s *StagePackageStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if s.Path == "" {
		return fmt.Errorf("path is required")
	}
	pkgPath := filepath.Clean(s.Path)
	digest, err := fileSHA256(pkgPath)
	if err != nil {
		return fmt.Errorf("compute sha256: %w", err)
	}
	if s.VerifySHA256 != "" && !strings.EqualFold(digest, s.VerifySHA256) {
		return fmt.Errorf("sha256 mismatch: got %s want %s", digest, s.VerifySHA256)
	}

	stagingDir := s.stagingDir(digest)
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		return fmt.Errorf("create staging dir: %w", err)
	}

	if err := extractPackage(pkgPath, stagingDir); err != nil {
		return err
	}

	manifestPath := filepath.Join(stagingDir, "package.json")
	mf, err := loadPackageManifest(manifestPath)
	if err != nil {
		return err
	}
	if s.RequireTypeService && mf.Type != "service" {
		return fmt.Errorf("unsupported package type %q", mf.Type)
	}
	if s.RequirePlatformMatch {
		platform := fmt.Sprintf("%s_%s", runtime.GOOS, runtime.GOARCH)
		if mf.Platform != "" && mf.Platform != platform {
			return fmt.Errorf("platform mismatch: package %s installer %s", mf.Platform, platform)
		}
	}
	if err := mf.ValidateDefaults(); err != nil {
		return err
	}

	ctx.StagingDir = stagingDir
	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		ctx.Runtime.StagedPackageName = mf.Name
		ctx.Runtime.StagedPackageVersion = mf.Version
		ctx.Runtime.StagedPackagePlatform = mf.Platform
		ctx.Runtime.StagedPackagePath = pkgPath
	}
	return nil
}

func (s *StagePackageStep) stagingDir(digest string) string {
	root := s.StagingRoot
	if root == "" {
		root = "/var/lib/globular/staging/packages"
	}
	return filepath.Join(root, digest)
}

func hasPackageJSON(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "package.json"))
	return err == nil && !info.IsDir()
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

func extractPackage(pkgPath, dest string) error {
	file, err := os.Open(pkgPath)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(hdr.Name)
		name = strings.TrimPrefix(name, "/")
		if name == "." || name == "" {
			continue
		}
		if strings.HasPrefix(name, "..") {
			return fmt.Errorf("package entry outside root: %s", hdr.Name)
		}
		target := filepath.Join(dest, name)
		if !strings.HasPrefix(target, dest+string(filepath.Separator)) && target != dest {
			return fmt.Errorf("invalid path traversal: %s", hdr.Name)
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, hdr.FileInfo().Mode())
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, tr); err != nil {
				out.Close()
				return err
			}
			out.Close()
		default:
			return fmt.Errorf("unsupported entry type %d for %s", hdr.Typeflag, hdr.Name)
		}
	}
	return nil
}

type PackageManifest struct {
	Type       string `json:"type"`
	Name       string `json:"name"`
	Version    string `json:"version"`
	Platform   string `json:"platform"`
	Publisher  string `json:"publisher"`
	Entrypoint string `json:"entrypoint"`
	Defaults   struct {
		ConfigDir string `json:"configDir"`
		Spec      string `json:"spec"`
	} `json:"defaults"`
}

func (m *PackageManifest) ValidateDefaults() error {
	if m.Defaults.ConfigDir != "" {
		if isUnsafePath(m.Defaults.ConfigDir) {
			return fmt.Errorf("invalid defaults.configDir: %s", m.Defaults.ConfigDir)
		}
	}
	if m.Defaults.Spec != "" {
		if isUnsafePath(m.Defaults.Spec) {
			return fmt.Errorf("invalid defaults.spec: %s", m.Defaults.Spec)
		}
	}
	return nil
}

func loadPackageManifest(path string) (*PackageManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest: %w", err)
	}
	var mf PackageManifest
	if err := json.Unmarshal(data, &mf); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	return &mf, nil
}

func isUnsafePath(p string) bool {
	clean := filepath.Clean(p)
	if strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
		return true
	}
	return clean == "." || clean == ""
}
