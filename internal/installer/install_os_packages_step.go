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

	// Install packages
	args := []string{"install", "-y"}
	args = append(args, s.Packages...)

	cmd := exec.Command("apt-get", args...)
	cmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")

	output, err := cmd.CombinedOutput()
	if err != nil {
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

	// Run apt-get update
	cmd := exec.Command("apt-get", "update")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("apt-get update failed: %w\nOutput: %s", err, string(output))
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

// detectDistro detects the OS distribution
func (s *InstallOSPackagesStep) detectDistro() (string, error) {
	// Read /etc/os-release
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "", fmt.Errorf("read /etc/os-release: %w", err)
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "ID=") {
			distro := strings.Trim(strings.TrimPrefix(line, "ID="), "\"")
			return strings.ToLower(distro), nil
		}
	}

	return "", fmt.Errorf("could not determine distribution from /etc/os-release")
}
