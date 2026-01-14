package installer

import (
	"context"
	"testing"
	"time"

	"github.com/globulario/globular-installer/internal/platform"
)

type flappingServiceManager struct {
	count int
}

func (f *flappingServiceManager) DaemonReload(ctx context.Context) error         { return nil }
func (f *flappingServiceManager) Enable(ctx context.Context, name string) error  { return nil }
func (f *flappingServiceManager) Disable(ctx context.Context, name string) error { return nil }
func (f *flappingServiceManager) Start(ctx context.Context, name string) error   { return nil }
func (f *flappingServiceManager) Stop(ctx context.Context, name string) error    { return nil }
func (f *flappingServiceManager) Restart(ctx context.Context, name string) error { return nil }
func (f *flappingServiceManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	state := platform.ServiceInactive
	if f.count > 2 {
		state = platform.ServiceActive
	}
	return platform.ServiceStatus{Name: name, State: state}, nil
}
func (f *flappingServiceManager) IsActive(ctx context.Context, name string) (bool, error) {
	f.count++
	return f.count > 2, nil
}
func (f *flappingServiceManager) IsEnabled(ctx context.Context, name string) (bool, error) {
	return true, nil
}

type healthPlatform struct {
	sm platform.ServiceManager
}

func (p *healthPlatform) Name() string { return "health" }
func (p *healthPlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (p *healthPlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error { return nil }
func (p *healthPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	return nil
}
func (p *healthPlatform) ServiceManager() platform.ServiceManager { return p.sm }

func TestHealthChecksWaitsUntilActive(t *testing.T) {
	sm := &flappingServiceManager{}
	ctx := &Context{Platform: &healthPlatform{sm: sm}}
	step := &HealthChecksStep{
		Services: []string{"foo.service"},
		Timeout:  2 * time.Second,
		Interval: 10 * time.Millisecond,
	}
	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected status ok, got %v", status)
	}
}
