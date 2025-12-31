package linux

import (
	"context"

	"github.com/globulario/globular-installer/internal/platform"
)

type Platform struct {
	sm platform.ServiceManager
}

func New() *Platform {
	return &Platform{sm: NewSystemdManager()}
}

func init() {
	platform.RegisterLinuxPlatform(func() platform.Platform {
		return New()
	})
}

func (p *Platform) Name() string {
	return "linux"
}

func (p *Platform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	_ = ctx
	_ = user
	_ = group
	return nil
}

func (p *Platform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error {
	return EnsureDirs(ctx, dirs)
}

func (p *Platform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	return InstallFiles(ctx, files)
}

func (p *Platform) ServiceManager() platform.ServiceManager {
	if p.sm == nil {
		p.sm = NewSystemdManager()
	}
	return p.sm
}
