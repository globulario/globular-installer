package installer

import (
	"context"
	"fmt"
	"time"

	"github.com/globulario/globular-installer/pkg/platform"
)

type HealthChecksStep struct {
	Services []string
	Timeout  time.Duration
	Interval time.Duration
}

func NewHealthChecksStep() *HealthChecksStep {
	return &HealthChecksStep{
		Timeout:  60 * time.Second,
		Interval: 2 * time.Second,
	}
}

func (s *HealthChecksStep) Name() string {
	return "health-checks"
}

func (s *HealthChecksStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.DryRun {
		// In dry-run we do not require real services to be running.
		return StatusSkipped, nil
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	if len(s.serviceList(ctx)) == 0 {
		return StatusUnknown, fmt.Errorf("health-checks step requires services list")
	}
	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return StatusUnknown, fmt.Errorf("service manager unavailable")
	}
	for _, unit := range s.serviceList(ctx) {
		if err := s.waitForActive(sm, unit); err != nil {
			return StatusFailed, err
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

	_, err := s.Check(ctx)
	return err
}

func (s *HealthChecksStep) serviceList(ctx *Context) []string {
	return s.Services
}

func (s *HealthChecksStep) waitForActive(sm platform.ServiceManager, unit string) error {
	timeout := s.Timeout
	interval := s.Interval
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	if interval <= 0 {
		interval = 2 * time.Second
	}
	deadline := time.Now().Add(timeout)
	var lastState platform.ServiceStatus
	for {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("is-active %s: %w", unit, err)
		}
		status, serr := sm.Status(context.Background(), unit)
		if serr == nil {
			lastState = status
		}
		if active {
			return nil
		}
		if status.State == platform.ServiceFailed {
			return fmt.Errorf("service %s failed (state=%v detail=%s)", unit, status.State, status.Detail)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("service %s not active after %s (state=%v detail=%s)", unit, timeout, lastState.State, lastState.Detail)
		}
		time.Sleep(interval)
	}
}
