package installer

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/globulario/globular-installer/internal/platform"
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
		specRoot = "/etc/globular/specs"
	}
	systemdRoot := s.SystemdDestRoot
	if systemdRoot == "" {
		systemdRoot = "/etc/systemd/system"
	}

	needsApply := false

	if s.InstallBins {
		dstBin := filepath.Join(prefix, filepath.Clean(manifest.Entrypoint))
		if _, err := os.Stat(dstBin); err != nil {
			if os.IsNotExist(err) {
				needsApply = true
			} else {
				return StatusUnknown, err
			}
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
		specRoot = "/etc/globular/specs"
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
	}

	if s.InstallSystemd {
		systemdDir := filepath.Join(ctx.StagingDir, "systemd")
		unitSpecs, err := collectServiceUnitSpecs(systemdDir, systemdRoot)
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

func collectServiceUnitSpecs(systemdDir, destRoot string) ([]platform.FileSpec, error) {
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
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(destRoot, name),
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   0o644,
			Atomic: true,
		})
	}
	return specs, nil
}
