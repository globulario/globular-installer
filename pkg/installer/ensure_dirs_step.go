package installer

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/pkg/platform"
)

const (
	systemUser  = "root"
	systemGroup = "root"
	appUser     = "globular"
	appGroup    = "globular"
)

type EnsureDirsStep struct {
	Dirs []platform.DirSpec
}

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
	for _, dir := range s.dirSpecs(ctx) {
		info, err := os.Stat(dir.Path)
		if err != nil {
			if os.IsNotExist(err) {
				return StatusNeedsApply, nil
			}
			return StatusUnknown, fmt.Errorf("stat %s: %w", dir.Path, err)
		}
		if !info.IsDir() {
			return StatusUnknown, fmt.Errorf("%s exists but is not a directory", dir.Path)
		}
	}
	return StatusOK, nil
}

func (s *EnsureDirsStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("context is required")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("platform is required")
	}

	if err := ctx.Platform.EnsureDirs(context.Background(), s.dirSpecs(ctx)); err != nil {
		return fmt.Errorf("ensure dirs: %w", err)
	}

	return nil
}

func (s *EnsureDirsStep) dirSpecs(ctx *Context) []platform.DirSpec {
	if len(s.Dirs) > 0 {
		return s.Dirs
	}
	prefix := ctx.Prefix
	stateDir := ctx.StateDir
	configDir := ctx.ConfigDir
	return []platform.DirSpec{
		{Path: prefix, Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: filepath.Join(prefix, "bin"), Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: stateDir, Owner: appUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: filepath.Join(stateDir, "data"), Owner: appUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: configDir, Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
		{Path: filepath.Join(configDir, "config"), Owner: systemUser, Group: appGroup, Mode: fs.FileMode(0o750)},
		{Path: filepath.Join(configDir, "features"), Owner: systemUser, Group: systemGroup, Mode: fs.FileMode(0o755)},
	}
}
