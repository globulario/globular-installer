package installer

import (
	"context"
	"testing"

	"github.com/globulario/globular-installer/internal/platform"
)

type enableRecordingSM struct {
	enabled map[string]bool
}

func (e *enableRecordingSM) DaemonReload(ctx context.Context) error         { return nil }
func (e *enableRecordingSM) Enable(ctx context.Context, name string) error  { e.enabled[name] = true; return nil }
func (e *enableRecordingSM) Disable(ctx context.Context, name string) error { return nil }
func (e *enableRecordingSM) Start(ctx context.Context, name string) error   { return nil }
func (e *enableRecordingSM) Stop(ctx context.Context, name string) error    { return nil }
func (e *enableRecordingSM) Restart(ctx context.Context, name string) error { return nil }
func (e *enableRecordingSM) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	return platform.ServiceStatus{Name: name, State: platform.ServiceActive}, nil
}
func (e *enableRecordingSM) IsActive(ctx context.Context, name string) (bool, error) {
	return false, nil
}
func (e *enableRecordingSM) IsEnabled(ctx context.Context, name string) (bool, error) {
	return e.enabled[name], nil
}

type enableRecordingPlatform struct {
	sm *enableRecordingSM
}

func (p *enableRecordingPlatform) Name() string { return "enable-rec" }
func (p *enableRecordingPlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (p *enableRecordingPlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error { return nil }
func (p *enableRecordingPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	return nil
}
func (p *enableRecordingPlatform) ServiceManager() platform.ServiceManager { return p.sm }

func TestEnableServicesStep(t *testing.T) {
	sm := &enableRecordingSM{enabled: make(map[string]bool)}
	plat := &enableRecordingPlatform{sm: sm}
	ctx := &Context{Platform: plat}

	step := &EnableServicesStep{Services: []string{"foo.service"}}

	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected needs-apply, got %v", status)
	}

	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}

	if !sm.enabled["foo.service"] {
		t.Fatalf("service was not enabled")
	}
}
