package installer

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// InstallOSPackagesStep installs OS packages via package manager (apt-get for Debian/Ubuntu)
type InstallOSPackagesStep struct {
	Packages []string
}

// NewInstallOSPackagesStep creates a new InstallOSPackagesStep
func NewInstallOSPackagesStep() *InstallOSPackagesStep {
	return &InstallOSPackagesStep{}
}

// Name returns the step name
func (s *InstallOSPackagesStep) Name() string {
	return "install-os-packages"
}

// Check verifies if packages are already installed
func (s *InstallOSPackagesStep) Check(ctx *Context) (StepStatus, error) {
	if len(s.Packages) == 0 {
		return StatusOK, nil // Nothing to install
	}

	// Check if all packages are installed
	allInstalled := true
	for _, pkg := range s.Packages {
		if !s.isPackageInstalled(pkg) {
			allInstalled = false
			break
		}
	}

	if allInstalled {
		return StatusOK, nil
	}
	return StatusNeedsApply, nil
}

// Apply installs the OS packages
func (s *InstallOSPackagesStep) Apply(ctx *Context) error {
	if len(s.Packages) == 0 {
		return nil // Nothing to install
	}

	// Detect OS type
	distro, err := s.detectDistro()
	if err != nil {
		return fmt.Errorf("detect OS distribution: %w", err)
	}

	switch distro {
	case "debian", "ubuntu":
		return s.installDebianPackages(ctx)
	default:
		return fmt.Errorf("unsupported distribution: %s (only Debian/Ubuntu supported)", distro)
	}
}

// installDebianPackages installs packages using apt-get
func (s *InstallOSPackagesStep) installDebianPackages(ctx *Context) error {
	// Update package cache if needed (use stamp file to avoid excessive updates)
	if err := s.updateAptCacheIfNeeded(ctx); err != nil {
		return fmt.Errorf("update apt cache: %w", err)
	}

	// Fix any broken/half-configured packages first — an unrelated broken
	// package (e.g. globular-minio) can cause dpkg to return non-zero even
	// when the packages we requested installed fine.
	// --force-confold: keep existing config files, never prompt interactively.
	fixCmd := exec.Command("dpkg", "--configure", "-a", "--force-confold")
	fixCmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
	if out, err := fixCmd.CombinedOutput(); err != nil {
		if ctx != nil && ctx.Logger != nil {
			ctx.Logger.Infof("dpkg --configure -a returned non-zero (continuing): %v\n%s", err, string(out))
		}
	}

	// Install packages
	// -o Dpkg::Options::=--force-confold: keep existing config files during
	// package install/upgrade — prevents dpkg from blocking on interactive
	// conffile prompts in non-interactive environments.
	args := []string{
		"-o", "Dpkg::Options::=--force-confold",
		"install", "-y", "--no-install-recommends",
	}
	args = append(args, s.Packages...)

	cmd := exec.Command("apt-get", args...)
	cmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")

	output, err := cmd.CombinedOutput()
	if err != nil {
		// apt-get may return non-zero due to unrelated broken packages even
		// though our requested packages installed successfully. Verify each
		// requested package before declaring failure.
		allInstalled := true
		for _, pkg := range s.Packages {
			if !s.isPackageInstalled(pkg) {
				allInstalled = false
				break
			}
		}
		if allInstalled {
			if ctx != nil && ctx.Logger != nil {
				ctx.Logger.Infof("apt-get returned non-zero but all requested packages are installed (ignoring): %v", err)
			}
			return nil
		}
		return fmt.Errorf("apt-get install failed: %w\nOutput: %s", err, string(output))
	}

	return nil
}

// updateAptCacheIfNeeded updates apt cache if it's stale (using stamp file)
func (s *InstallOSPackagesStep) updateAptCacheIfNeeded(ctx *Context) error {
	stampFile := "/var/lib/globular/.apt-update-stamp"
	stampMaxAge := 24 * time.Hour

	// Check stamp file age
	info, err := os.Stat(stampFile)
	if err == nil {
		age := time.Since(info.ModTime())
		if age < stampMaxAge {
			// Cache is recent, skip update
			return nil
		}
	}

	// Run apt-get update. Ignore failures from unrelated third-party repos
	// (e.g. expired GPG keys) — they shouldn't block installing our packages.
	cmd := exec.Command("apt-get", "update")
	output, err := cmd.CombinedOutput()
	if err != nil {
		outStr := string(output)
		if ctx != nil && ctx.Logger != nil {
			ctx.Logger.Infof("apt-get update returned non-zero (continuing): %v", err)
		}
		// Only fail if there are NO valid package lists at all
		if !strings.Contains(outStr, "Hit:") && !strings.Contains(outStr, "Get:") {
			return fmt.Errorf("apt-get update failed: %w\nOutput: %s", err, outStr)
		}
	}

	// Update stamp file
	stampDir := filepath.Dir(stampFile)
	if err := os.MkdirAll(stampDir, 0755); err != nil {
		// Continue even if stamp dir creation fails
	}
	if err := os.WriteFile(stampFile, []byte(time.Now().Format(time.RFC3339)), 0644); err != nil {
		// Continue even if stamp file write fails
	}

	return nil
}

// isPackageInstalled checks if a package is installed via dpkg
func (s *InstallOSPackagesStep) isPackageInstalled(pkg string) bool {
	cmd := exec.Command("dpkg", "-s", pkg)
	err := cmd.Run()
	return err == nil
}

// detectDistro detects the OS distribution.
// For derivatives (e.g. Linux Mint, Pop!_OS), falls back to ID_LIKE
// to match the parent distro (debian/ubuntu).
func (s *InstallOSPackagesStep) detectDistro() (string, error) {
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "", fmt.Errorf("read /etc/os-release: %w", err)
	}

	var id, idLike string
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "ID=") {
			id = strings.ToLower(strings.Trim(strings.TrimPrefix(line, "ID="), "\""))
		} else if strings.HasPrefix(line, "ID_LIKE=") {
			idLike = strings.ToLower(strings.Trim(strings.TrimPrefix(line, "ID_LIKE="), "\""))
		}
	}

	if id == "" {
		return "", fmt.Errorf("could not determine distribution from /etc/os-release")
	}

	// Direct match (debian, ubuntu)
	switch id {
	case "debian", "ubuntu":
		return id, nil
	}

	// Derivative match via ID_LIKE (e.g. linuxmint → "ubuntu debian")
	for _, parent := range strings.Fields(idLike) {
		switch parent {
		case "debian", "ubuntu":
			return parent, nil
		}
	}

	return id, nil
}
