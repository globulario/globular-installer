package installer

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/globulario/globular-installer/internal/platform"
)

func TestStartServicesStepAutoHealsPortClash(t *testing.T) {
	tmp := t.TempDir()
	clashPort := 61001
	binDir := filepath.Join(tmp, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	bin := makeFakeDescribeBinary(t, binDir, "rbac-id", "localhost:"+strconv.Itoa(clashPort))

	cfgPath := filepath.Join(tmp, "rbac-id.json")
	writeJSONConfig(t, cfgPath, map[string]any{
		"Address": "localhost:" + strconv.Itoa(clashPort),
		"Port":    clashPort,
	})

	mgr := &startFakeServiceManager{}
	plat := &startFakePlatform{sm: mgr}

	rangeStart := clashPort
	rangeEnd := clashPort + 5

	originalProbe := portProbe
	portProbe = func(int) bool { return true }
	defer func() { portProbe = originalProbe }()

	alloc := mustPortAllocator(t, rangeStart, rangeEnd)
	// Simulate port already reserved/taken.
	_, _ = alloc.Reserve("existing", clashPort)

	ctx := &Context{
		Prefix:    tmp,
		ConfigDir: tmp,
		Platform:  plat,
		Ports:     alloc,
		Runtime:   &RuntimeState{ChangedFiles: map[string]bool{}},
	}

	step := &StartServicesStep{
		Services: []string{"globular-rbac.service"},
		Binaries: map[string]string{"globular-rbac.service": filepath.Base(bin)},
	}

	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if !mgr.started["globular-rbac.service"] {
		t.Fatalf("service was not started")
	}

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read cfg: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal cfg: %v", err)
	}
	port := int(cfg["Port"].(float64))
	if port == clashPort || port < rangeStart || port > rangeEnd {
		t.Fatalf("port not healed: %d", port)
	}
}

func TestStartTimeEnsureFreePortDescribeFailureIsBestEffort(t *testing.T) {
	tmp := t.TempDir()
	binDir := filepath.Join(tmp, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	failBin := makeFailBinary(t, binDir, 2)
	ctx := &Context{
		Prefix:    tmp,
		ConfigDir: tmp,
		Platform:  &startFakePlatform{sm: &startFakeServiceManager{}},
		Ports:     mustPortAllocator(t, 10000, 10010),
	}
	if err := startTimeEnsureFreePort(ctx, "globular-fail.service", filepath.Base(failBin)); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
}

func TestStartServicesStepDryRunNoRestartWhenActive(t *testing.T) {
	mgr := &startFakeServiceManager{
		active: map[string]bool{"svc.service": true},
	}
	plat := &startFakePlatform{sm: mgr}
	ctx := &Context{
		Platform: plat,
		DryRun:   true,
	}
	step := &StartServicesStep{
		Services: []string{"svc.service"},
		Binaries: map[string]string{"svc.service": "svc-bin"},
	}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if mgr.started["svc.service"] {
		t.Fatalf("dry-run should not start service")
	}
}

type startFakeServiceManager struct {
	started map[string]bool
	active  map[string]bool
}

func (s *startFakeServiceManager) DaemonReload(ctx context.Context) error { return nil }
func (s *startFakeServiceManager) Enable(ctx context.Context, name string) error {
	return nil
}
func (s *startFakeServiceManager) Disable(ctx context.Context, name string) error { return nil }
func (s *startFakeServiceManager) Start(ctx context.Context, name string) error {
	if s.started == nil {
		s.started = map[string]bool{}
	}
	s.started[name] = true
	return nil
}
func (s *startFakeServiceManager) Stop(ctx context.Context, name string) error    { return nil }
func (s *startFakeServiceManager) Restart(ctx context.Context, name string) error { return nil }
func (s *startFakeServiceManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	return platform.ServiceStatus{Name: name}, nil
}
func (s *startFakeServiceManager) IsActive(ctx context.Context, name string) (bool, error) {
	if s.active == nil {
		return false, nil
	}
	return s.active[name], nil
}
func (s *startFakeServiceManager) IsEnabled(ctx context.Context, name string) (bool, error) {
	return false, nil
}

type startFakePlatform struct {
	sm    platform.ServiceManager
	files []platform.FileSpec
}

func (p *startFakePlatform) Name() string { return "start-fake" }
func (p *startFakePlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (p *startFakePlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error {
	return nil
}
func (p *startFakePlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	p.files = append(p.files, files...)
	for _, f := range files {
		if err := os.MkdirAll(filepath.Dir(f.Path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(f.Path, f.Data, f.Mode); err != nil {
			return err
		}
	}
	return nil
}
func (p *startFakePlatform) ServiceManager() platform.ServiceManager { return p.sm }

func makeFailBinary(t *testing.T, dir string, exitCode int) string {
	t.Helper()
	path := filepath.Join(dir, "fail.sh")
	content := "#!/bin/sh\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write fail bin: %v", err)
	}
	return path
}
