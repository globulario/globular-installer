package installer

import (
	"fmt"
	"os"

	"github.com/globulario/globular-installer/pkg/platform"
)

type UninstallFilesStep struct {
	Files []platform.FileSpec
}

func NewUninstallFilesStep() *UninstallFilesStep { return &UninstallFilesStep{} }

func (s *UninstallFilesStep) Name() string { return "uninstall-files" }

func (s *UninstallFilesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	for _, file := range s.Files {
		if _, err := os.Stat(file.Path); err == nil {
			return StatusNeedsApply, nil
		} else if !os.IsNotExist(err) {
			return StatusUnknown, err
		}
	}
	return StatusOK, nil
}

func (s *UninstallFilesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	for _, file := range s.Files {
		if ctx.DryRun {
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would remove file %s", file.Path)
			}
			continue
		}
		if err := os.Remove(file.Path); err != nil {
			if !os.IsNotExist(err) {
				return fmt.Errorf("remove %s: %w", file.Path, err)
			}
		}
	}
	return nil
}
