package installer

import (
	"bytes"
	"context"
	"fmt"
	"io"
	iofs "io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/globulario/globular-installer/internal/assets"
	"github.com/globulario/globular-installer/internal/platform"
)

type InstallBinariesStep struct{}

func NewInstallBinariesStep() *InstallBinariesStep {
	return &InstallBinariesStep{}
}

func (s *InstallBinariesStep) Name() string {
	return "install-binaries"
}

func (s *InstallBinariesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	specs, _, err := s.desiredSpecs(ctx)
	if err != nil {
		return StatusUnknown, err
	}
	if len(specs) == 0 {
		return StatusOK, nil
	}
	if ctx.Force {
		return StatusNeedsApply, nil
	}
	for _, spec := range specs {
		info, err := os.Stat(spec.Path)
		if err != nil {
			if os.IsNotExist(err) {
				return StatusNeedsApply, nil
			}
			return StatusUnknown, err
		}
		data, err := os.ReadFile(spec.Path)
		if err != nil {
			return StatusUnknown, err
		}
		if !bytes.Equal(spec.Data, data) {
			return StatusNeedsApply, nil
		}
		if spec.Mode != 0 {
			if info.Mode().Perm() != spec.Mode.Perm() {
				return StatusNeedsApply, nil
			}
		}
	}
	return StatusOK, nil
}

func (s *InstallBinariesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}
	if ctx.StagingDir != "" {
		return s.installFromStaging(ctx)
	}
	return s.installFromEmbedded(ctx)
}

func (s *InstallBinariesStep) installFromStaging(ctx *Context) error {
	specs, source, err := s.desiredSpecs(ctx)
	if err != nil {
		return fmt.Errorf("read staging bins: %w", err)
	}
	return s.deploySpecs(ctx, specs, source)
}

func (s *InstallBinariesStep) installFromEmbedded(ctx *Context) error {
	specs, source, err := s.desiredSpecs(ctx)
	if err != nil {
		if ctx.Logger != nil {
			ctx.Logger.Infof("install-binaries: embedded bundle not available: %v", err)
		}
		return nil
	}
	return s.deploySpecs(ctx, specs, source)
}

func buildSpecsFromDir(srcBin, prefix string) ([]platform.FileSpec, error) {
	entries, err := os.ReadDir(srcBin)
	if err != nil {
		return nil, err
	}
	specs := make([]platform.FileSpec, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, fmt.Errorf("stat %s: %w", entry.Name(), err)
		}
		if !info.Mode().IsRegular() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(srcBin, entry.Name()))
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", entry.Name(), err)
		}
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(prefix, "bin", entry.Name()),
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   iofs.FileMode(0o755),
			Atomic: true,
		})
	}
	return specs, nil
}

func (s *InstallBinariesStep) desiredSpecs(ctx *Context) ([]platform.FileSpec, string, error) {
	if ctx.StagingDir != "" {
		srcBin := filepath.Join(ctx.StagingDir, "bin")
		specs, err := buildSpecsFromDir(srcBin, ctx.Prefix)
		return specs, srcBin, err
	}
	specs, err := buildEmbeddedSpecs(ctx)
	return specs, "embedded bundle", err
}

func buildEmbeddedSpecs(ctx *Context) ([]platform.FileSpec, error) {
	binFS := assets.BinFS()
	entries, err := iofs.ReadDir(binFS, ".")
	if err != nil {
		return nil, err
	}
	specs := make([]platform.FileSpec, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || shouldSkipEmbedded(entry.Name()) {
			continue
		}
		f, err := binFS.Open(entry.Name())
		if err != nil {
			return nil, err
		}
		data, err := io.ReadAll(f)
		if closeErr := f.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
		if err != nil {
			return nil, err
		}
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(ctx.Prefix, "bin", entry.Name()),
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   iofs.FileMode(0o755),
			Atomic: true,
		})
	}
	return specs, nil
}

func (s *InstallBinariesStep) deploySpecs(ctx *Context, specs []platform.FileSpec, source string) error {
	if len(specs) == 0 {
		if ctx.Logger != nil {
			ctx.Logger.Infof("install-binaries: no binaries found in %s", source)
		}
		return nil
	}
	if ctx.Logger != nil {
		ctx.Logger.Infof("install-binaries: preparing %d binary(s) from %s", len(specs), source)
	}
	if ctx.DryRun {
		if ctx.Logger != nil {
			for _, spec := range specs {
				ctx.Logger.Infof("dry-run: would install binary %s", spec.Path)
			}
		}
		return nil
	}
	changed := make([]string, 0, len(specs))
	if installer, ok := ctx.Platform.(platform.FileInstallerWithResult); ok {
		result, err := installer.InstallFilesWithResult(context.Background(), specs)
		if err != nil {
			return fmt.Errorf("install binaries: %w", err)
		}
		changed = append(changed, result.Changed...)
	} else {
		if err := ctx.Platform.InstallFiles(context.Background(), specs); err != nil {
			return fmt.Errorf("install binaries: %w", err)
		}
		for _, spec := range specs {
			changed = append(changed, spec.Path)
		}
	}
	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		for _, path := range changed {
			ctx.Runtime.ChangedBinaries[path] = true
		}
	}
	return nil
}

func hasEmbeddedBins() bool {
	fs := assets.BinFS()
	entries, err := iofs.ReadDir(fs, ".")
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if shouldSkipEmbedded(entry.Name()) {
			continue
		}
		return true
	}
	return false
}

func shouldSkipEmbedded(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	if strings.HasSuffix(name, ".gitkeep") {
		return true
	}
	return false
}
