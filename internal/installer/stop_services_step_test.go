package installer

import (
	"context"
	"fmt"
	"testing"

	"github.com/globulario/globular-installer/internal/platform"
)

type fakeServiceManager struct {
	active     map[string]bool
	activeErr  map[string]error
	enabled    map[string]bool
	enabledErr map[string]error
	reloads    int
	disableErr map[string]error
	stopErr    map[string]error
}

func (f *fakeServiceManager) DaemonReload(ctx context.Context) error {
	f.reloads++
	return nil
}

func (f *fakeServiceManager) Enable(ctx context.Context, name string) error { return nil }
func (f *fakeServiceManager) Disable(ctx context.Context, name string) error {
	if err := f.disableErr[name]; err != nil {
		return err
	}
	return nil
}
func (f *fakeServiceManager) Start(ctx context.Context, name string) error { return nil }
func (f *fakeServiceManager) Stop(ctx context.Context, name string) error {
	if err := f.stopErr[name]; err != nil {
		return err
	}
	return nil
}
func (f *fakeServiceManager) Restart(ctx context.Context, name string) error { return nil }
func (f *fakeServiceManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	return platform.ServiceStatus{Name: name, State: platform.ServiceUnknown}, nil
}

func (f *fakeServiceManager) IsActive(ctx context.Context, name string) (bool, error) {
	if err := f.activeErr[name]; err != nil {
		return false, err
	}
	return f.active[name], nil
}

func (f *fakeServiceManager) IsEnabled(ctx context.Context, name string) (bool, error) {
	if err := f.enabledErr[name]; err != nil {
		return false, err
	}
	return f.enabled[name], nil
}

type fakePlatform struct {
	sm platform.ServiceManager
}

func (f *fakePlatform) ServiceManager() platform.ServiceManager { return f.sm }
func (f *fakePlatform) Name() string                            { return "fake" }
func (f *fakePlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (f *fakePlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error { return nil }
func (f *fakePlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	return nil
}

func TestStopServicesStepCheckActiveOrEnabled(t *testing.T) {
	mgr := &fakeServiceManager{
		active:  map[string]bool{"globular-envoy.service": true},
		enabled: map[string]bool{},
	}
	ctx := &Context{Platform: &fakePlatform{sm: mgr}}
	step := &StopServicesStep{Services: []string{"globular-envoy.service"}}
	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check failed: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected NeedsApply, got %v", status)
	}
}

func TestStopServicesStepCheckMissingService(t *testing.T) {
	mgr := &fakeServiceManager{
		activeErr:  map[string]error{"missing.service": fmt.Errorf("Unit missing.service not-found")},
		enabledErr: map[string]error{"missing.service": fmt.Errorf("Unit missing.service not-found")},
	}
	ctx := &Context{Platform: &fakePlatform{sm: mgr}}
	step := &StopServicesStep{Services: []string{"missing.service"}}
	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check failed: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected OK, got %v", status)
	}
}

func TestUninstallFilesDoesNotReload(t *testing.T) {
	mgr := &fakeServiceManager{}
	ctx := &Context{Platform: &fakePlatform{sm: mgr}}
	step := &UninstallFilesStep{Files: []platform.FileSpec{{Path: "/tmp/nonexistent"}}}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	if mgr.reloads != 0 {
		t.Fatalf("expected zero reloads, got %d", mgr.reloads)
	}
}

func TestStopServicesStepApplyIgnoresNotFound(t *testing.T) {
	errNotFound := fmt.Errorf("Unit missing.service not found")
	mgr := &fakeServiceManager{
		disableErr: map[string]error{"missing.service": errNotFound},
		stopErr:    map[string]error{"missing.service": errNotFound},
	}
	ctx := &Context{Platform: &fakePlatform{sm: mgr}}
	step := &StopServicesStep{Services: []string{"missing.service"}}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply failed: %v", err)
	}
}
