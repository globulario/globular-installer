package installer

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// InstallLocalDebsStep installs .deb packages bundled inside the staged
// package artifact. This eliminates the need for internet access at
// install time — all dependencies are resolved at build time.
//
// The step looks for .deb files in {StagingDir}/debs/ and installs them
// with dpkg. If no debs/ directory exists, the step is a no-op (StatusOK).
type InstallLocalDebsStep struct {
	// DebsSubdir is the subdirectory under StagingDir containing .deb files.
	// Defaults to "debs" if empty.
	DebsSubdir string
}

func NewInstallLocalDebsStep() *InstallLocalDebsStep {
	return &InstallLocalDebsStep{DebsSubdir: "debs"}
}

func (s *InstallLocalDebsStep) Name() string {
	return "install-local-debs"
}

func (s *InstallLocalDebsStep) Check(ctx *Context) (StepStatus, error) {
	debsDir := s.debsDir(ctx)
	debs, err := findDebs(debsDir)
	if err != nil || len(debs) == 0 {
		return StatusOK, nil // no debs bundled — skip
	}

	// Check if all debs are already installed.
	allInstalled := true
	for _, deb := range debs {
		pkg := debPackageName(deb)
		if pkg != "" && !isDebInstalled(pkg) {
			allInstalled = false
			break
		}
	}
	if allInstalled {
		return StatusOK, nil
	}
	return StatusNeedsApply, nil
}

func (s *InstallLocalDebsStep) Apply(ctx *Context) error {
	debsDir := s.debsDir(ctx)
	debs, err := findDebs(debsDir)
	if err != nil || len(debs) == 0 {
		log.Printf("[install-local-debs] no .deb files in %s, skipping", debsDir)
		return nil
	}

	log.Printf("[install-local-debs] installing %d .deb files from %s", len(debs), debsDir)

	// Install all debs in one dpkg call for dependency resolution.
	args := append([]string{"-i", "--force-confold"}, debs...)
	cmd := exec.Command("dpkg", args...)
	cmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		// dpkg may fail on unresolved dependencies. Try apt-get -f install to fix.
		log.Printf("[install-local-debs] dpkg returned error, attempting apt-get -f install to resolve dependencies")
		fixCmd := exec.Command("apt-get", "install", "-f", "-y", "--no-install-recommends")
		fixCmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
		fixCmd.Stdout = os.Stdout
		fixCmd.Stderr = os.Stderr
		if fixErr := fixCmd.Run(); fixErr != nil {
			return fmt.Errorf("install local debs failed: dpkg: %v, apt-get -f: %v", err, fixErr)
		}
	}

	// Verify all packages installed.
	var failed []string
	for _, deb := range debs {
		pkg := debPackageName(deb)
		if pkg != "" && !isDebInstalled(pkg) {
			failed = append(failed, pkg)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("install local debs: packages not installed after dpkg: %s", strings.Join(failed, ", "))
	}

	log.Printf("[install-local-debs] %d packages installed successfully", len(debs))
	return nil
}

func (s *InstallLocalDebsStep) debsDir(ctx *Context) string {
	sub := s.DebsSubdir
	if sub == "" {
		sub = "debs"
	}
	return filepath.Join(ctx.StagingDir, sub)
}

// findDebs returns absolute paths of all .deb files in a directory.
func findDebs(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var debs []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".deb") {
			debs = append(debs, filepath.Join(dir, e.Name()))
		}
	}
	return debs, nil
}

// debPackageName extracts the package name from a .deb filename.
// e.g. "scylla-server_2025.3.8-1_amd64.deb" → "scylla-server"
func debPackageName(debPath string) string {
	base := filepath.Base(debPath)
	parts := strings.SplitN(base, "_", 2)
	if len(parts) < 1 {
		return ""
	}
	return parts[0]
}

// isDebInstalled checks if a package is installed via dpkg.
func isDebInstalled(pkg string) bool {
	out, err := exec.Command("dpkg", "-s", pkg).Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "Status: install ok installed")
}
