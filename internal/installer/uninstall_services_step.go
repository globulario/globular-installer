package installer

import (
	"context"
	"fmt"
	"os"

	"github.com/globulario/globular-installer/internal/platform"
)

type UninstallServicesStep struct {
	Units []platform.FileSpec
}

func NewUninstallServicesStep() *UninstallServicesStep { return &UninstallServicesStep{} }

func (s *UninstallServicesStep) Name() string { return "uninstall-services" }

func (s *UninstallServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	for _, unit := range s.Units {
		if _, err := os.Stat(unit.Path); err == nil {
			return StatusNeedsApply, nil
		} else if !os.IsNotExist(err) {
			return StatusUnknown, err
		}
	}
	return StatusOK, nil
}

func (s *UninstallServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	var removed bool
	for _, unit := range s.Units {
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would remove unit %s", unit.Path)
			}
			continue
		}
		if err := os.Remove(unit.Path); err != nil {
			if !os.IsNotExist(err) {
				return fmt.Errorf("remove %s: %w", unit.Path, err)
			}
		} else {
			removed = true
		}
	}
	if removed && ctx.Platform != nil {
		if sm := ctx.Platform.ServiceManager(); sm != nil {
			if err := sm.DaemonReload(context.Background()); err != nil {
				return fmt.Errorf("daemon-reload: %w", err)
			}
		}
	}
	return nil
}
