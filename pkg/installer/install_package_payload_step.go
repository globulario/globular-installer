package installer

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"text/template"

	"github.com/globulario/globular-installer/pkg/platform"
)

// InstallPackagePayloadStep installs config, specs, and systemd units from a staged package.
type InstallPackagePayloadStep struct {
	Prefix          string
	InstallBins     bool
	InstallConfig   bool
	InstallSpec     bool
	InstallSystemd  bool
	ConfigDestRoot  string
	SpecDestRoot    string
	SystemdDestRoot string
	ReloadSystemd   bool
}

func (s *InstallPackagePayloadStep) Name() string { return "install-package-payload" }

func (s *InstallPackagePayloadStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.StagingDir == "" {
		return StatusUnknown, fmt.Errorf("staging dir not set; run stage_package first")
	}

	manifest, err := loadPackageManifest(filepath.Join(ctx.StagingDir, "package.json"))
	if err != nil {
		return StatusUnknown, err
	}
	if err := manifest.ValidateDefaults(); err != nil {
		return StatusUnknown, err
	}

	prefix := s.Prefix
	if prefix == "" {
		prefix = ctx.Prefix
	}
	cfgRoot := s.ConfigDestRoot
	if cfgRoot == "" {
		cfgRoot = ctx.ConfigDir
	}
	specRoot := s.SpecDestRoot
	if specRoot == "" {
		specRoot = "/var/lib/globular/specs"
	}
	systemdRoot := s.SystemdDestRoot
	if systemdRoot == "" {
		systemdRoot = "/etc/systemd/system"
	}

	needsApply := false

	if s.InstallBins {
		// Check if binaries need installation/update by delegating to InstallBinariesStep
		binStep := &InstallBinariesStep{}
		status, err := binStep.Check(ctx)
		if err != nil {
			return StatusUnknown, err
		}
		if status == StatusNeedsApply {
			needsApply = true
		}
	}

	if s.InstallConfig && manifest.Defaults.ConfigDir != "" {
		destRoot := filepath.Join(cfgRoot, manifest.Name)
		if _, err := os.Stat(destRoot); err != nil {
			if os.IsNotExist(err) {
				needsApply = true
			} else {
				return StatusUnknown, err
			}
		}
	}

	if s.InstallSpec && manifest.Defaults.Spec != "" {
		srcSpec := filepath.Join(ctx.StagingDir, filepath.Clean(manifest.Defaults.Spec))
		dstSpec := filepath.Join(specRoot, filepath.Base(srcSpec))
		if _, err := os.Stat(dstSpec); err != nil {
			if os.IsNotExist(err) {
				needsApply = true
			} else {
				return StatusUnknown, err
			}
		}
	}

	if s.InstallSystemd {
		systemdDir := filepath.Join(ctx.StagingDir, "systemd")
		entries, err := os.ReadDir(systemdDir)
		if err != nil && !os.IsNotExist(err) {
			return StatusUnknown, err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			if !strings.HasSuffix(entry.Name(), ".service") {
				continue
			}
			dstUnit := filepath.Join(systemdRoot, entry.Name())
			if _, err := os.Stat(dstUnit); err != nil {
				if os.IsNotExist(err) {
					needsApply = true
					break
				}
				return StatusUnknown, err
			}
		}
	}

	if needsApply {
		return StatusNeedsApply, nil
	}
	return StatusOK, nil
}

func (s *InstallPackagePayloadStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}
	if ctx.StagingDir == "" {
		return fmt.Errorf("staging dir not set; run stage_package first")
	}

	manifest, err := loadPackageManifest(filepath.Join(ctx.StagingDir, "package.json"))
	if err != nil {
		return err
	}
	if err := manifest.ValidateDefaults(); err != nil {
		return err
	}

	svcName := manifest.Name
	prefix := s.Prefix
	if prefix == "" {
		prefix = ctx.Prefix
	}
	cfgRoot := s.ConfigDestRoot
	if cfgRoot == "" {
		cfgRoot = ctx.ConfigDir
	}
	specRoot := s.SpecDestRoot
	if specRoot == "" {
		specRoot = "/var/lib/globular/specs"
	}
	systemdRoot := s.SystemdDestRoot
	if systemdRoot == "" {
		systemdRoot = "/etc/systemd/system"
	}

	files := []platform.FileSpec{}

	if s.InstallConfig {
		if manifest.Defaults.ConfigDir != "" {
			srcCfg := filepath.Join(ctx.StagingDir, filepath.Clean(manifest.Defaults.ConfigDir))
			destRoot := filepath.Join(cfgRoot, svcName)
			cfgSpecs, err := collectFileSpecs(srcCfg, destRoot, 0o644)
			if err != nil {
				return fmt.Errorf("collect config: %w", err)
			}
			files = append(files, cfgSpecs...)
		}
	}

	if s.InstallSpec {
		if manifest.Defaults.Spec != "" {
			srcSpec := filepath.Join(ctx.StagingDir, filepath.Clean(manifest.Defaults.Spec))
			data, err := os.ReadFile(srcSpec)
			if err != nil {
				return fmt.Errorf("read spec: %w", err)
			}
			dst := filepath.Join(specRoot, filepath.Base(srcSpec))
			files = append(files, platform.FileSpec{Path: dst, Data: data, Owner: "root", Group: "root", Mode: 0o644, Atomic: true})
		}
	}

	if len(files) > 0 {
		if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
			return fmt.Errorf("install files: %w", err)
		}
		if ctx.Runtime != nil {
			ensureRuntimeMaps(ctx.Runtime)
			for _, spec := range files {
				ctx.Runtime.ChangedFiles[spec.Path] = true
			}
		}
	}

	if s.InstallBins {
		binStep := &InstallBinariesStep{}
		if err := binStep.Apply(ctx); err != nil {
			return fmt.Errorf("install binaries: %w", err)
		}

		// Canonicalize mc: ensure /usr/lib/globular/bin/mc exists and mc_cmd is removed
		// This handles legacy packages that may have installed mc_cmd
		if manifest.Name == "mc-cmd" {
			binDir := filepath.Join(prefix, "bin")
			legacy := filepath.Join(binDir, "mc_cmd")
			canonical := filepath.Join(binDir, "mc")

			legacyInfo, legacyErr := os.Stat(legacy)
			canonicalInfo, canonicalErr := os.Stat(canonical)

			legacyExists := legacyErr == nil && legacyInfo.Mode().IsRegular()
			canonicalExists := canonicalErr == nil && canonicalInfo.Mode().IsRegular()

			switch {
			case legacyExists && !canonicalExists:
				// Rename mc_cmd -> mc
				if err := os.Rename(legacy, canonical); err != nil {
					return fmt.Errorf("rename mc_cmd to mc: %w", err)
				}
			case legacyExists && canonicalExists:
				// Both exist, remove mc_cmd
				if err := os.Remove(legacy); err != nil {
					return fmt.Errorf("remove legacy mc_cmd: %w", err)
				}
			}

			// Ensure mc is executable
			if _, err := os.Stat(canonical); err == nil {
				if err := os.Chmod(canonical, 0755); err != nil {
					return fmt.Errorf("chmod mc: %w", err)
				}
			}
		}

		// Canonicalize globularcli: ensure /usr/lib/globular/bin/globularcli exists and globular_cli_cmd is removed
		// This handles legacy packages that may have installed globular_cli_cmd
		if manifest.Name == "globular-cli-cmd" {
			binDir := filepath.Join(prefix, "bin")
			legacy := filepath.Join(binDir, "globular_cli_cmd")
			canonical := filepath.Join(binDir, "globularcli")

			legacyInfo, legacyErr := os.Stat(legacy)
			canonicalInfo, canonicalErr := os.Stat(canonical)

			legacyExists := legacyErr == nil && legacyInfo.Mode().IsRegular()
			canonicalExists := canonicalErr == nil && canonicalInfo.Mode().IsRegular()

			switch {
			case legacyExists && !canonicalExists:
				// Rename globular_cli_cmd -> globularcli
				if err := os.Rename(legacy, canonical); err != nil {
					return fmt.Errorf("rename globular_cli_cmd to globularcli: %w", err)
				}
			case legacyExists && canonicalExists:
				// Both exist, remove globular_cli_cmd
				if err := os.Remove(legacy); err != nil {
					return fmt.Errorf("remove legacy globular_cli_cmd: %w", err)
				}
			}

			// Ensure globularcli is executable
			if _, err := os.Stat(canonical); err == nil {
				if err := os.Chmod(canonical, 0755); err != nil {
					return fmt.Errorf("chmod globularcli: %w", err)
				}
			}
		}
	}

	if s.InstallSystemd {
		systemdDir := filepath.Join(ctx.StagingDir, "systemd")
		unitSpecs, err := collectServiceUnitSpecs(systemdDir, systemdRoot, ctx)
		if err != nil {
			return err
		}
		if len(unitSpecs) > 0 {
			if err := ctx.Platform.InstallFiles(context.Background(), unitSpecs); err != nil {
				return fmt.Errorf("install systemd units: %w", err)
			}
			if ctx.Runtime != nil {
				ensureRuntimeMaps(ctx.Runtime)
				for _, spec := range unitSpecs {
					ctx.Runtime.ChangedUnits[filepath.Base(spec.Path)] = true
					ctx.Runtime.ChangedFiles[spec.Path] = true
				}
			}
			if s.ReloadSystemd || (!s.InstallConfig && !s.InstallSpec) {
				if mgr := ctx.Platform.ServiceManager(); mgr != nil {
					if err := mgr.DaemonReload(context.Background()); err != nil {
						return fmt.Errorf("daemon-reload: %w", err)
					}
				}
			}
		}
	}

	return nil
}

func collectFileSpecs(srcRoot, destRoot string, mode fs.FileMode) ([]platform.FileSpec, error) {
	specs := []platform.FileSpec{}
	info, err := os.Stat(srcRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return specs, nil
		}
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("config source %s is not a directory", srcRoot)
	}
	err = filepath.WalkDir(srcRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(destRoot, rel),
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   mode,
			Atomic: true,
		})
		return nil
	})
	return specs, err
}

func collectServiceUnitSpecs(systemdDir, destRoot string, ctx *Context) ([]platform.FileSpec, error) {
	specs := []platform.FileSpec{}
	info, err := os.Stat(systemdDir)
	if err != nil {
		if os.IsNotExist(err) {
			return specs, nil
		}
		return nil, err
	}
	if !info.IsDir() {
		return specs, nil
	}
	entries, err := os.ReadDir(systemdDir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".service") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(systemdDir, name))
		if err != nil {
			return nil, err
		}
		// Expand template variables if context is available
		expandedData := data
		if ctx != nil && ctx.TemplateVars != nil {
			expanded, err := expandTemplateString(string(data), ctx.TemplateVars)
			if err != nil {
				return nil, fmt.Errorf("expand templates in %s: %w", name, err)
			}
			expandedData = []byte(expanded)
		}
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(destRoot, name),
			Data:   expandedData,
			Owner:  "root",
			Group:  "root",
			Mode:   0o644,
			Atomic: true,
		})
	}
	return specs, nil
}

// expandTemplateString expands Go template variables in a string using the provided vars map.
// This uses the same template expansion logic as the spec loader.
func expandTemplateString(input string, vars map[string]string) (string, error) {
	tmpl, err := template.New("").Option("missingkey=error").Parse(input)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, vars); err != nil {
		return "", err
	}
	return buf.String(), nil
}
