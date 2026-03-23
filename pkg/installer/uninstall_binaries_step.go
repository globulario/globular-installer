package installer

import (
	"fmt"
	"os"
)

type UninstallBinariesStep struct {
	Paths []string
}

func NewUninstallBinariesStep() *UninstallBinariesStep { return &UninstallBinariesStep{} }

func (s *UninstallBinariesStep) Name() string { return "uninstall-binaries" }

func (s *UninstallBinariesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	for _, path := range s.Paths {
		if _, err := os.Stat(path); err == nil {
			return StatusNeedsApply, nil
		} else if !os.IsNotExist(err) {
			return StatusUnknown, err
		}
	}
	return StatusOK, nil
}

func (s *UninstallBinariesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	for _, path := range s.Paths {
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would remove binary %s", path)
			}
			continue
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove %s: %w", path, err)
		}
	}
	return nil
}
