package installer

import (
	"context"
	"fmt"
)

type HealthChecksStep struct {
	Services []string
}

func NewHealthChecksStep() *HealthChecksStep {
	return &HealthChecksStep{}
}

func (s *HealthChecksStep) Name() string {
	return "health-checks"
}

func (s *HealthChecksStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return StatusUnknown, fmt.Errorf("service manager unavailable")
	}
	for _, unit := range s.serviceList(ctx) {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return StatusUnknown, fmt.Errorf("is-active %s: %w", unit, err)
		}
		if !active {
			status, serr := sm.Status(context.Background(), unit)
			if serr != nil {
				return StatusFailed, fmt.Errorf("status %s: %w", unit, serr)
			}
			return StatusFailed, fmt.Errorf("service %s not active (state=%v detail=%s)", unit, status.State, status.Detail)
		}
	}
	return StatusOK, nil
}

func (s *HealthChecksStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: skipping health checks")
		}
		return nil
	}

	status, err := s.Check(ctx)
	if err != nil {
		return err
	}
	if status != StatusOK {
		return fmt.Errorf("health checks failed: %s", status.String())
	}
	return nil
}

func (s *HealthChecksStep) serviceList(ctx *Context) []string {
	if len(s.Services) > 0 {
		return s.Services
	}
	return enabledServices(ctx)
}
