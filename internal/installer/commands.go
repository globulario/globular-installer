package installer

import (
	"fmt"

	"github.com/globulario/globular-installer/internal/installer/spec"
)

func Install(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}

	sp := ctx.Spec
	if sp == nil {
		sp = spec.DefaultInstallSpec(map[string]string{
			"Prefix":    ctx.Prefix,
			"StateDir":  ctx.StateDir,
			"ConfigDir": ctx.ConfigDir,
			"Version":   ctx.Version,
		})
	}

	plan, err := BuildInstallPlan(ctx, sp)
	if err != nil {
		return nil, err
	}

	return NewRunner().Run(ctx, plan, ModeApply)
}

func Upgrade(ctx *Context) (*RunReport, error) {
	plan := NewPlan("upgrade", NewNoop("upgrade-placeholder"))
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	return NewRunner().Run(ctx, plan, ModeCheckOnly)
}

func Uninstall(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	sp := ctx.Spec
	if sp == nil {
		sp = spec.DefaultInstallSpec(map[string]string{
			"Prefix":    ctx.Prefix,
			"StateDir":  ctx.StateDir,
			"ConfigDir": ctx.ConfigDir,
			"Version":   ctx.Version,
		})
	}
	preflight := NewPlan("uninstall-preflight",
		NewRequireRootStep(),
		NewCheckSystemdStep(),
	)
	runner := NewRunner()
	if _, err := runner.Run(ctx, preflight, ModeApply); err != nil {
		return nil, err
	}
	plan, err := BuildUninstallPlan(ctx, sp)
	if err != nil {
		return nil, err
	}
	return runner.Run(ctx, plan, ModeApply)
}

func Doctor(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	preflight := NewPlan("doctor",
		NewRequireRootStep(),
		NewCheckSystemdStep(),
		NewCheckCommandsStep(nil),
	)
	return NewRunner().Run(ctx, preflight, ModeCheckOnly)
}

func Repair(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	plan := NewPlan("repair", NewNoop("repair-placeholder"))
	return NewRunner().Run(ctx, plan, ModeCheckOnly)
}

func Status(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	plan := NewPlan("status", NewNoop("status-placeholder"))
	return NewRunner().Run(ctx, plan, ModeCheckOnly)
}
