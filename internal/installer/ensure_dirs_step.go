package installer

import (
	"context"
	"fmt"
	"io/fs"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/platform"
)

const (
	systemUser  = "root"
	systemGroup = "root"
	appUser     = "globular"
	appGroup    = "globular"
)

type EnsureDirsStep struct{}

func NewEnsureDirs() *EnsureDirsStep {
	return &EnsureDirsStep{}
}

func (s *EnsureDirsStep) Name() string {
	return "ensure-dirs"
}

func (s *EnsureDirsStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("context is required")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("platform is required")
	}
	return StatusNeedsApply, nil
}

func (s *EnsureDirsStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("context is required")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("platform is required")
	}

	prefix := ctx.Prefix
	stateDir := ctx.StateDir
	configDir := ctx.ConfigDir

	dirs := []platform.DirSpec{
		{Path: prefix, Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: filepath.Join(prefix, "bin"), Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: stateDir, Owner: appUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: filepath.Join(stateDir, "data"), Owner: appUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: configDir, Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: filepath.Join(configDir, "config"), Owner: systemUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: filepath.Join(configDir, "features"), Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
	}

	if err := ctx.Platform.EnsureDirs(context.Background(), dirs); err != nil {
		return fmt.Errorf("ensure dirs: %w", err)
	}

	return nil
}
