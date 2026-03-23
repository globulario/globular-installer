package installer

import (
	"context"
	"fmt"
	"strings"
)

type StopServicesStep struct {
	Services []string
}

func NewStopServicesStep() *StopServicesStep { return &StopServicesStep{} }

func (s *StopServicesStep) Name() string { return "stop-services" }

func (s *StopServicesStep) Check(ctx *Context) (StepStatus, error) {
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
	for _, unit := range s.Services {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil && !isServiceNotFound(err) {
			return StatusUnknown, err
		}
		enabled, err := sm.IsEnabled(context.Background(), unit)
		if err != nil && !isServiceNotFound(err) {
			return StatusUnknown, err
		}
		if active || enabled {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *StopServicesStep) Apply(ctx *Context) error {
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
	for _, unit := range s.Services {
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would disable %s", unit)
				ctx.Logger.Infof("dry-run: would stop %s", unit)
			}
			continue
		}
		if err := sm.Disable(context.Background(), unit); err != nil && !isServiceNotFound(err) {
			return fmt.Errorf("disable %s: %w", unit, err)
		}
		if err := sm.Stop(context.Background(), unit); err != nil && !isServiceNotFound(err) {
			return fmt.Errorf("stop %s: %w", unit, err)
		}
	}
	return nil
}

func isServiceNotFound(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "not found") ||
		strings.Contains(msg, "not-found") ||
		strings.Contains(msg, "could not be found") ||
		strings.Contains(msg, "loaded: not-found")
}
