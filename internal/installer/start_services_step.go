package installer

import (
	"context"
	"fmt"
	"path/filepath"
)

type StartServicesStep struct {
	Services       []string
	RestartOnFiles map[string][]string
}

func NewStartServicesStep() *StartServicesStep {
	return &StartServicesStep{}
}

func (s *StartServicesStep) Name() string {
	return "start-services"
}

func (s *StartServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	units := s.serviceList(ctx)
	if len(units) == 0 {
		return StatusUnknown, fmt.Errorf("start-services step requires services list")
	}
	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return StatusUnknown, fmt.Errorf("service manager unavailable")
	}
	for _, unit := range units {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return StatusUnknown, fmt.Errorf("is-active %s: %w", unit, err)
		}
		if !active {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *StartServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}

	units := s.serviceList(ctx)
	for _, unit := range units {
		restartNeeded := s.needsRestart(ctx, unit)
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would enable %s", unit)
				ctx.Logger.Infof("dry-run: would start %s", unit)
				if restartNeeded {
					ctx.Logger.Infof("dry-run: would restart %s", unit)
				}
			}
			continue
		}
		if err := sm.Enable(context.Background(), unit); err != nil {
			return fmt.Errorf("enable %s: %w", unit, err)
		}
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("is-active %s: %w", unit, err)
		}
		if !active {
			if err := sm.Start(context.Background(), unit); err != nil {
				return fmt.Errorf("start %s: %w", unit, err)
			}
			continue
		}
		if restartNeeded {
			if err := sm.Restart(context.Background(), unit); err != nil {
				return fmt.Errorf("restart %s: %w", unit, err)
			}
		}
	}

	return nil
}

func (s *StartServicesStep) serviceList(ctx *Context) []string {
	return s.Services
}

func prefixedBinaryPath(ctx *Context, name string) string {
	return filepath.Join(ctx.Prefix, "bin", name)
}

func (s *StartServicesStep) needsRestart(ctx *Context, unit string) bool {
	if ctx == nil || ctx.Runtime == nil {
		return false
	}
	if ctx.Runtime.ChangedUnits[unitPath(unit)] {
		return true
	}
	if ctx.Runtime.ChangedUnits[unit] {
		return true
	}
	for _, file := range s.RestartOnFiles[unit] {
		if ctx.Runtime.ChangedFiles[file] {
			return true
		}
	}
	if bin := unitBinary(unit); bin != "" {
		if ctx.Runtime.ChangedBinaries[prefixedBinaryPath(ctx, bin)] {
			return true
		}
	}
	return false
}

func unitPath(unit string) string {
	return filepath.Join("/etc/systemd/system", unit)
}

func unitBinary(unit string) string {
	switch unit {
	case "globular-xds.service":
		return "xds"
	case "globular-gateway.service":
		return "gateway"
	case "globular-envoy.service":
		return "envoy"
	case "globular-etcd.service":
		return "etcd"
	default:
		return ""
	}
}
