package installer

import (
	"context"
	"fmt"
)

type EnableServicesStep struct {
	Services []string
}

func NewEnableServicesStep() *EnableServicesStep {
	return &EnableServicesStep{}
}

func (s *EnableServicesStep) Name() string { return "enable-services" }

func (s *EnableServicesStep) serviceList(ctx *Context) []string {
	return s.Services
}

func (s *EnableServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	services := s.serviceList(ctx)
	if len(services) == 0 {
		return StatusUnknown, fmt.Errorf("enable-services step requires services list")
	}
	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return StatusUnknown, fmt.Errorf("service manager unavailable")
	}
	for _, unit := range services {
		enabled, err := sm.IsEnabled(context.Background(), unit)
		if err != nil {
			return StatusUnknown, fmt.Errorf("is-enabled %s: %w", unit, err)
		}
		if !enabled {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *EnableServicesStep) Apply(ctx *Context) error {
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

	services := s.serviceList(ctx)
	if len(services) == 0 {
		return fmt.Errorf("enable-services step requires services list")
	}

	for _, unit := range services {
		enabled, err := sm.IsEnabled(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("is-enabled %s: %w", unit, err)
		}
		if enabled {
			continue
		}
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would enable %s", unit)
			}
			continue
		}
		if err := sm.Enable(context.Background(), unit); err != nil {
			return fmt.Errorf("enable %s: %w", unit, err)
		}
	}
	return nil
}
