package installer

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// ExtractPackageToTemp untars a tgz package into a temporary directory and returns
// the staging path.
func ExtractPackageToTemp(pkgPath string) (string, error) {
	info, err := os.Stat(pkgPath)
	if err != nil {
		return "", fmt.Errorf("stat package: %w", err)
	}
	if info.IsDir() {
		return "", fmt.Errorf("package path %s is a directory", pkgPath)
	}
	f, err := os.Open(pkgPath)
	if err != nil {
		return "", fmt.Errorf("open package: %w", err)
	}
	defer f.Close()

	gzr, err := gzip.NewReader(f)
	if err != nil {
		return "", fmt.Errorf("gzip: %w", err)
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	dst, err := os.MkdirTemp("", "globular-package-*")
	if err != nil {
		return "", fmt.Errorf("mkdir temp: %w", err)
	}

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", fmt.Errorf("read tar: %w", err)
		}
		target := filepath.Join(dst, filepath.Clean(hdr.Name))
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(hdr.Mode)); err != nil {
				return "", fmt.Errorf("mkdir %s: %w", target, err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return "", fmt.Errorf("mkdir %s: %w", filepath.Dir(target), err)
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_RDWR|os.O_TRUNC, os.FileMode(hdr.Mode))
			if err != nil {
				return "", fmt.Errorf("create %s: %w", target, err)
			}
			if _, err := io.Copy(out, tr); err != nil {
				out.Close()
				return "", fmt.Errorf("write %s: %w", target, err)
			}
			out.Close()
		default:
			// skip other entry types
		}
	}

	return dst, nil
}
