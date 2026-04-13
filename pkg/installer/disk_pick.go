package installer

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// diskCandidate describes a mounted filesystem the installer considers
// for placing MinIO object data on. Network/pseudo filesystems and OS
// mounts are filtered out by scanDataMounts().
type diskCandidate struct {
	MountPoint string // e.g. "/mnt/data"
	Device     string // e.g. "/dev/sdb1"
	FSType     string // e.g. "ext4"
	TotalBytes uint64
	FreeBytes  uint64
}

// scanDataMounts returns local writable filesystems that are reasonable
// candidates for application data storage (MinIO, etc.). Excludes:
// loopback, network, pseudo, and OS-critical mounts ( /, /boot, /home).
func scanDataMounts() []diskCandidate {
	// Reject pseudo / network / container filesystems we never want to
	// store bulk data on.
	excludedFS := map[string]bool{
		"tmpfs": true, "devtmpfs": true, "proc": true, "sysfs": true,
		"cgroup": true, "cgroup2": true, "pstore": true, "devpts": true,
		"securityfs": true, "debugfs": true, "tracefs": true,
		"nfs": true, "nfs4": true, "cifs": true, "smb3": true, "9p": true,
		"fuse.gvfsd-fuse": true, "autofs": true, "mqueue": true, "hugetlbfs": true,
		"fusectl": true, "bpf": true, "ramfs": true, "squashfs": true,
	}
	// Reject mount prefixes that are OS-critical or clearly wrong for
	// bulk data (caller also rejects "/" itself).
	excludedPrefixes := []string{
		"/boot", "/dev", "/proc", "/sys", "/run", "/snap", "/var/lib/docker",
		"/var/lib/containers", "/media", "/cdrom", "/mnt/cdrom",
	}

	f, err := os.Open("/proc/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []diskCandidate
	seen := make(map[string]bool)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 4 {
			continue
		}
		device, mount, fstype := fields[0], fields[1], fields[2]
		if seen[mount] {
			continue
		}
		seen[mount] = true
		if excludedFS[fstype] {
			continue
		}
		if mount == "/" || mount == "/boot" || mount == "/boot/efi" || mount == "/home" {
			continue
		}
		rejected := false
		for _, pfx := range excludedPrefixes {
			if mount == pfx || strings.HasPrefix(mount, pfx+"/") {
				rejected = true
				break
			}
		}
		if rejected {
			continue
		}
		// Only real block devices (paths under /dev/). This filters bind
		// mounts, overlayfs, and other synthetic sources.
		if !strings.HasPrefix(device, "/dev/") {
			continue
		}
		// Check that the mount is writable by the caller — os.Stat +
		// a probe file. Failures here just skip the candidate.
		var st syscall.Statfs_t
		if err := syscall.Statfs(mount, &st); err != nil {
			continue
		}
		total := st.Blocks * uint64(st.Bsize)
		free := st.Bavail * uint64(st.Bsize)
		if total == 0 {
			continue
		}
		out = append(out, diskCandidate{
			MountPoint: mount,
			Device:     device,
			FSType:     fstype,
			TotalBytes: total,
			FreeBytes:  free,
		})
	}
	// Stable order: largest free bytes first, ties broken by mount point.
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].FreeBytes != out[j].FreeBytes {
			return out[i].FreeBytes > out[j].FreeBytes
		}
		return out[i].MountPoint < out[j].MountPoint
	})
	return out
}

const minMinioDiskFreeBytes = 10 * 1024 * 1024 * 1024 // 10 GiB floor

// pickBestMinioDataDir returns the best candidate path for MinIO data,
// or the provided defaultPath when no suitable non-root disk is available.
// The returned path is always under a cluster-owned subdirectory ("minio/data")
// so the installer's ensure-dirs step can create it with correct ownership.
func pickBestMinioDataDir(defaultPath string) (chosen string, candidate *diskCandidate) {
	mounts := scanDataMounts()
	for i := range mounts {
		if mounts[i].FreeBytes < minMinioDiskFreeBytes {
			continue
		}
		// Smoke-test writability by creating/removing a probe file.
		if !isMountWritable(mounts[i].MountPoint) {
			continue
		}
		return filepath.Join(mounts[i].MountPoint, "minio", "data"), &mounts[i]
	}
	return defaultPath, nil
}

func isMountWritable(mount string) bool {
	probe := filepath.Join(mount, ".globular-install-probe")
	f, err := os.Create(probe)
	if err != nil {
		return false
	}
	f.Close()
	_ = os.Remove(probe)
	return true
}

// promptUserForMinioDisk interactively asks the user to pick a disk for MinIO
// from the detected candidates plus the fallback. Accepts the number matching
// the candidate order (1-based) or empty (Enter) for the default. Falls back
// silently to the auto-picked value on any error or EOF.
//
// When `preselect` is non-nil, it is used as the default — shown as [1] in
// the prompt.
func promptUserForMinioDisk(defaultPath string, candidates []diskCandidate, preselect *diskCandidate) string {
	if len(candidates) == 0 {
		return defaultPath
	}
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "MinIO object-store data directory")
	fmt.Fprintln(os.Stderr, "─────────────────────────────────")
	fmt.Fprintln(os.Stderr, "Detected mounted filesystems (storage for buckets/objects):")
	fmt.Fprintln(os.Stderr, "")
	for i, c := range candidates {
		marker := "  "
		if preselect != nil && c.MountPoint == preselect.MountPoint {
			marker = "➤ "
		}
		fmt.Fprintf(os.Stderr, "%s[%d] %-25s  %-7s  %8s free of %8s  (%s)\n",
			marker, i+1, c.MountPoint, c.FSType,
			fmtHumanBytes(c.FreeBytes), fmtHumanBytes(c.TotalBytes), c.Device)
	}
	fmt.Fprintf(os.Stderr, "  [0] use default (%s)\n", defaultPath)
	fmt.Fprintln(os.Stderr, "")

	defaultIdx := 0
	if preselect != nil {
		for i, c := range candidates {
			if c.MountPoint == preselect.MountPoint {
				defaultIdx = i + 1
				break
			}
		}
	}
	fmt.Fprintf(os.Stderr, "Select disk [%d]: ", defaultIdx)

	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		if preselect != nil {
			return filepath.Join(preselect.MountPoint, "minio", "data")
		}
		return defaultPath
	}
	line := strings.TrimSpace(sc.Text())
	if line == "" {
		if preselect != nil {
			return filepath.Join(preselect.MountPoint, "minio", "data")
		}
		return defaultPath
	}
	var idx int
	if _, err := fmt.Sscanf(line, "%d", &idx); err != nil || idx < 0 || idx > len(candidates) {
		fmt.Fprintln(os.Stderr, "invalid selection, using default")
		return defaultPath
	}
	if idx == 0 {
		return defaultPath
	}
	return filepath.Join(candidates[idx-1].MountPoint, "minio", "data")
}

func fmtHumanBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}
