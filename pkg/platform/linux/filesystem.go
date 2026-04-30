package linux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/globulario/globular-installer/pkg/platform"
)

// sharedRoots are directories that must remain world-traversable (0755)
// regardless of what individual service specs declare. A service spec
// must not restrict the shared state root — only private subdirectories
// should be 0750/0700.
var sharedRoots = map[string]bool{
	"/var/lib/globular":     true,
	"/var/lib/globular/pki": true, // CA cert (0644) must be readable by non-root CLI
}

func EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error {
	for _, dir := range dirs {
		if err := validateAbsPath(dir.Path); err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := os.MkdirAll(dir.Path, 0o755); err != nil {
			if errors.Is(err, fs.ErrExist) {
				// continue
			} else {
				return err
			}
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		mode := dir.Mode
		if mode != 0 {
			// Guard: shared roots must stay world-traversable. If a spec
			// declares 0750 on /var/lib/globular, force it to 0755.
			if sharedRoots[filepath.Clean(dir.Path)] && mode&0o005 == 0 {
				mode = mode | 0o005 // add world r+x
			}
			if err := applyMode(dir.Path, mode); err != nil {
				return err
			}
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if dir.Owner != "" || dir.Group != "" {
			if err := applyOwnership(dir.Path, dir.Owner, dir.Group); err != nil {
				return err
			}
		}
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	return nil
}

func InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	for _, file := range files {
		if _, err := installOneFile(ctx, file); err != nil {
			return err
		}
	}
	return nil
}

func InstallFilesWithResult(ctx context.Context, files []platform.FileSpec) (platform.InstallFilesResult, error) {
	var result platform.InstallFilesResult
	for _, file := range files {
		if changed, err := installOneFile(ctx, file); err != nil {
			return platform.InstallFilesResult{}, err
		} else if changed {
			result.Changed = append(result.Changed, file.Path)
		}
	}
	return result, nil
}

func installOneFile(ctx context.Context, file platform.FileSpec) (bool, error) {
	if err := validateAbsPath(file.Path); err != nil {
		return false, err
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	dir := filepath.Dir(file.Path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		if !errors.Is(err, fs.ErrExist) {
			return false, err
		}
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	// seed-only guard: if the file already exists and the caller asked us not
	// to overwrite it, leave it untouched.  This protects cluster-identity
	// configs (etcd.yaml, scylla.yaml, …) from being reset to single-node
	// defaults on every package reinstall.
	if file.SkipIfExists {
		if _, err := os.Stat(file.Path); err == nil {
			return false, nil // file exists — preserve it
		}
	}

	equal, err := fileContentEquals(file.Path, file.Data)
	if err != nil {
		return false, err
	}
	if equal {
		if err := maybeApplyOwnershipMode(file.Path, file.Owner, file.Group, file.Mode); err != nil {
			return false, err
		}
		return false, nil
	}
	if file.Atomic {
		if err := writeAtomic(ctx, file, dir); err != nil {
			return false, err
		}
	} else {
		if err := os.WriteFile(file.Path, file.Data, defaultFileMode(file.Mode)); err != nil {
			return false, err
		}
		if err := maybeApplyOwnershipMode(file.Path, file.Owner, file.Group, file.Mode); err != nil {
			return false, err
		}
	}
	return true, nil
}

func writeAtomic(ctx context.Context, file platform.FileSpec, dir string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".globular-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	success := false
	defer func() {
		tmp.Close()
		if !success {
			os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(file.Data); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		tmp.Close()
		return err
	}
	mode := defaultFileMode(file.Mode)
	if err := tmp.Chmod(mode); err != nil {
		return fmt.Errorf("chmod temp: %w", err)
	}
	if file.Owner != "" || file.Group != "" {
		if err := applyOwnership(tmpPath, file.Owner, file.Group); err != nil {
			return err
		}
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, file.Path); err != nil {
		return err
	}
	if err := maybeApplyOwnershipMode(file.Path, file.Owner, file.Group, file.Mode); err != nil {
		return err
	}
	success = true
	return nil
}

func maybeApplyOwnershipMode(path, owner, group string, mode fs.FileMode) error {
	if mode != 0 {
		if err := applyMode(path, mode); err != nil {
			return err
		}
	}
	if owner != "" || group != "" {
		if err := applyOwnership(path, owner, group); err != nil {
			return err
		}
	}
	return nil
}

func defaultFileMode(mode fs.FileMode) fs.FileMode {
	if mode != 0 {
		return mode
	}
	return 0o644
}

func validateAbsPath(p string) error {
	if strings.TrimSpace(p) == "" {
		return fmt.Errorf("path is empty")
	}
	if !filepath.IsAbs(p) {
		return fmt.Errorf("path %q is not absolute", p)
	}
	return nil
}

func fileContentEquals(path string, data []byte) (bool, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	return bytes.Equal(buf, data), nil
}

func applyOwnership(path, owner, group string) error {
	if owner == "" && group == "" {
		return nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("unsupported stat type for %s", path)
	}
	uid := int(stat.Uid)
	gid := int(stat.Gid)
	if owner != "" {
		if resolved, err := lookupUID(owner); err == nil {
			uid = resolved
		} else {
			return err
		}
	}
	if group != "" {
		if resolved, err := lookupGID(group); err == nil {
			gid = resolved
		} else {
			return err
		}
	}
	return os.Chown(path, uid, gid)
}

func applyMode(path string, mode fs.FileMode) error {
	if mode == 0 {
		return nil
	}
	return os.Chmod(path, mode)
}

func lookupUID(username string) (int, error) {
	if username == "" {
		return -1, nil
	}
	if uid, _, err := parsePasswd(username); err == nil {
		return uid, nil
	}
	if line, err := getent("passwd", username); err == nil {
		parts := strings.Split(line, ":")
		if len(parts) > 2 {
			if i, err := strconv.Atoi(parts[2]); err == nil {
				return i, nil
			}
		}
	}
	return -1, fmt.Errorf("user %q not found", username)
}

func lookupGID(group string) (int, error) {
	if group == "" {
		return -1, nil
	}
	if gid, err := parseGroup(group); err == nil {
		return gid, nil
	}
	if line, err := getent("group", group); err == nil {
		parts := strings.Split(line, ":")
		if len(parts) > 2 {
			if i, err := strconv.Atoi(parts[2]); err == nil {
				return i, nil
			}
		}
	}
	return -1, fmt.Errorf("group %q not found", group)
}

func parsePasswd(user string) (int, int, error) {
	data, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return -1, -1, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) < 4 {
			continue
		}
		if parts[0] != user {
			continue
		}
		uid, err := strconv.Atoi(parts[2])
		if err != nil {
			return -1, -1, err
		}
		gid, err := strconv.Atoi(parts[3])
		if err != nil {
			return -1, -1, err
		}
		return uid, gid, nil
	}
	return -1, -1, fmt.Errorf("user %q not found", user)
}

func parseGroup(group string) (int, error) {
	data, err := os.ReadFile("/etc/group")
	if err != nil {
		return -1, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) < 3 {
			continue
		}
		if parts[0] != group {
			continue
		}
		gid, err := strconv.Atoi(parts[2])
		if err != nil {
			return -1, err
		}
		return gid, nil
	}
	return -1, fmt.Errorf("group %q not found", group)
}

func getent(db, name string) (string, error) {
	out, err := exec.Command("getent", db, name).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
