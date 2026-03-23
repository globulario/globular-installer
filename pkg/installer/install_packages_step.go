package installer

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// PackageSpec describes a package and optional version constraint.
type PackageSpec struct {
	Name    string
	Version string
}

// InstallPackagesStep installs system packages via a package manager.
type InstallPackagesStep struct {
	Manager  string
	Packages []PackageSpec
}

func NewInstallPackagesStep() *InstallPackagesStep {
	return &InstallPackagesStep{}
}

func (s *InstallPackagesStep) Name() string {
	return "install-packages"
}

func (s *InstallPackagesStep) normalizeAndValidate() error {
	if s.Manager == "" {
		s.Manager = "apt"
	}
	if s.Manager != "apt" {
		return fmt.Errorf("unsupported package manager %q", s.Manager)
	}
	if len(s.Packages) == 0 {
		return fmt.Errorf("no packages declared")
	}
	return nil
}

func (s *InstallPackagesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if err := s.normalizeAndValidate(); err != nil {
		return StatusUnknown, err
	}
	for _, pkg := range s.Packages {
		installed, version, err := queryPackage(context.Background(), pkg.Name)
		if err != nil {
			return StatusUnknown, err
		}
		if !installed {
			return StatusNeedsApply, nil
		}
		ok, err := versionSatisfies(context.Background(), version, pkg.Version)
		if err != nil {
			return StatusUnknown, err
		}
		if !ok {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *InstallPackagesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if err := s.normalizeAndValidate(); err != nil {
		return err
	}
	if ctx.DryRun {
		if ctx.Logger != nil {
			for _, pkg := range s.Packages {
				ctx.Logger.Infof("dry-run: would install package %s %s", pkg.Name, pkg.Version)
			}
		}
		return nil
	}
	if err := runAptUpdate(ctx); err != nil {
		return err
	}
	args := []string{"install", "-y"}
	for _, pkg := range s.Packages {
		if pkg.Version != "" && strings.HasPrefix(pkg.Version, "=") {
			args = append(args, fmt.Sprintf("%s=%s", pkg.Name, strings.TrimPrefix(pkg.Version, "=")))
		} else {
			args = append(args, pkg.Name)
		}
	}
	cmd := exec.CommandContext(context.Background(), "apt-get", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("apt-get %v: %s: %w", args, strings.TrimSpace(string(output)), err)
	}
	return nil
}

func queryPackage(ctx context.Context, name string) (bool, string, error) {
	cmd := exec.CommandContext(ctx, "dpkg-query", "-W", "-f=${Status} ${Version}", name)
	output, err := cmd.Output()
	if err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return false, "", nil
		}
		return false, "", fmt.Errorf("dpkg-query %s: %w", name, err)
	}
	text := strings.TrimSpace(string(output))
	if !strings.Contains(text, "install ok installed") {
		return false, "", nil
	}
	parts := strings.Fields(text)
	if len(parts) < 4 {
		return false, "", fmt.Errorf("unexpected dpkg-query output %q for %s", text, name)
	}
	return true, parts[len(parts)-1], nil
}

func versionSatisfies(ctx context.Context, actual, constraint string) (bool, error) {
	if constraint == "" {
		return true, nil
	}
	op, version, err := parseVersionConstraint(constraint)
	if err != nil {
		return false, err
	}
	if version == "" {
		return true, nil
	}
	cmp := exec.CommandContext(ctx, "dpkg", "--compare-versions", actual, op, version)
	if err := cmp.Run(); err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return false, nil
		}
		return false, fmt.Errorf("dpkg --compare-versions %s %s %s: %w", actual, op, version, err)
	}
	return true, nil
}

func parseVersionConstraint(spec string) (string, string, error) {
	switch {
	case strings.HasPrefix(spec, ">="):
		return "ge", strings.TrimPrefix(spec, ">="), nil
	case strings.HasPrefix(spec, "<="):
		return "le", strings.TrimPrefix(spec, "<="), nil
	case strings.HasPrefix(spec, ">"):
		return "gt", strings.TrimPrefix(spec, ">"), nil
	case strings.HasPrefix(spec, "<"):
		return "lt", strings.TrimPrefix(spec, "<"), nil
	case strings.HasPrefix(spec, "="):
		return "eq", strings.TrimPrefix(spec, "="), nil
	default:
		return "", "", fmt.Errorf("unsupported version constraint %q", spec)
	}
}

func runAptUpdate(ctx *Context) error {
	cmd := exec.CommandContext(context.Background(), "apt-get", "update")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("apt-get update: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}
