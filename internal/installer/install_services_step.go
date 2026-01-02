package installer

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/platform"
)

type InstallServicesStep struct {
	Units []platform.FileSpec
}

func NewInstallServicesStep() *InstallServicesStep {
	return &InstallServicesStep{}
}

func (s *InstallServicesStep) Name() string {
	return "install-services"
}

func (s *InstallServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	files := s.unitsToInstall(ctx)
	if len(files) == 0 {
		return StatusOK, nil
	}
	for _, spec := range files {
		data, err := os.ReadFile(spec.Path)
		if err != nil {
			if os.IsNotExist(err) {
				return StatusNeedsApply, nil
			}
			return StatusUnknown, fmt.Errorf("read %s: %w", spec.Path, err)
		}
		if !bytes.Equal(data, spec.Data) {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *InstallServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	files := s.unitsToInstall(ctx)
	if len(files) == 0 {
		return nil
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: would install %d service units", len(files))
		}
		return nil
	}

	changedCount := 0
	if installerWithResult, ok := ctx.Platform.(platform.FileInstallerWithResult); ok {
		result, err := installerWithResult.InstallFilesWithResult(context.Background(), files)
		if err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		if ctx.Runtime != nil {
			ensureRuntimeMaps(ctx.Runtime)
		}
		for _, path := range result.Changed {
			if ctx.Runtime != nil {
				ctx.Runtime.ChangedUnits[path] = true
				ctx.Runtime.ChangedUnits[filepath.Base(path)] = true
			}
		}
		changedCount = len(result.Changed)
	} else {
		if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		changedCount = len(files)
		if ctx.Runtime != nil {
			ensureRuntimeMaps(ctx.Runtime)
			for _, spec := range files {
				ctx.Runtime.ChangedUnits[spec.Path] = true
				ctx.Runtime.ChangedUnits[filepath.Base(spec.Path)] = true
			}
		}
	}

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}
	if changedCount > 0 {
		if err := sm.DaemonReload(context.Background()); err != nil {
			return fmt.Errorf("daemon-reload: %w", err)
		}
	} else if ctx.Logger != nil {
		ctx.Logger.Infof("install-services: no unit changes; skipping daemon-reload")
	}

	return nil
}

func (s *InstallServicesStep) unitsToInstall(ctx *Context) []platform.FileSpec {
	return s.Units
}
