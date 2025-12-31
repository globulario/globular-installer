package installer

import "fmt"

func Install(ctx *Context) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}

	plan := NewPlan("install",
		NewEnsureUserGroup("", ""),
		NewEnsureDirs(),
		NewInstallBinariesStep(),
		NewInstallFilesStep(),
		NewInstallServicesStep(),
		NewStartServicesStep(),
		NewHealthChecksStep(),
		NewNoop("install-placeholder"),
	)

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
	plan := NewPlan("uninstall", NewNoop("uninstall-placeholder"))
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	return NewRunner().Run(ctx, plan, ModeCheckOnly)
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
