package installer

import (
	"context"
	"fmt"
)

type HealthChecksStep struct{}

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
	return StatusNeedsApply, nil
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

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}

	for _, unit := range enabledServiceUnitsHealth(ctx) {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("is-active %s: %w", unit, err)
		}
		if active {
			continue
		}
		status, err := sm.Status(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("status %s: %w", unit, err)
		}
		return fmt.Errorf("service %s not active (state=%v detail=%s)", unit, status.State, status.Detail)
	}

	return nil
}

func enabledServiceUnitsHealth(ctx *Context) []string {
	out := make([]string, 0, 3)
	if ctx.Features.Enabled(FeatureEnvoy) {
		out = append(out, "globular-envoy.service")
	}
	if ctx.Features.Enabled(FeatureXDS) {
		out = append(out, "globular-xds.service")
	}
	if ctx.Features.Enabled(FeatureGateway) {
		out = append(out, "globular-gateway.service")
	}
	return out
}
