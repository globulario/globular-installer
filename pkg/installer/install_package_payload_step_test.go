package installer

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/pkg/platform"
)

type recordingPlatform struct {
	files []platform.FileSpec
	sm    platform.ServiceManager
}

func (p *recordingPlatform) Name() string { return "recording" }
func (p *recordingPlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (p *recordingPlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error {
	return nil
}
func (p *recordingPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	p.files = append(p.files, files...)
	return nil
}
func (p *recordingPlatform) ServiceManager() platform.ServiceManager { return p.sm }

func TestInstallPackagePayloadInstallsFiles(t *testing.T) {
	staging := t.TempDir()
	pkgJSON := `{"type":"service","name":"svc","version":"1.0.0","platform":"linux_amd64","defaults":{"configDir":"config/svc","spec":"specs/svc.yaml"}}`
	mustWriteFile(t, filepath.Join(staging, "package.json"), []byte(pkgJSON))
	mustMkdir(t, filepath.Join(staging, "config", "svc"))
	mustWriteFile(t, filepath.Join(staging, "config", "svc", "a.conf"), []byte("cfg"))
	mustMkdir(t, filepath.Join(staging, "specs"))
	mustWriteFile(t, filepath.Join(staging, "specs", "svc.yaml"), []byte("spec"))
	mustMkdir(t, filepath.Join(staging, "systemd"))
	mustWriteFile(t, filepath.Join(staging, "systemd", "svc.service"), []byte("[Unit]\n"))

	sm := &reloadServiceManager{}
	plat := &recordingPlatform{sm: sm}
	ctx := &Context{StagingDir: staging, Platform: plat, Runtime: &RuntimeState{}, ConfigDir: DefaultConfigDir}

	step := &InstallPackagePayloadStep{InstallBins: false, InstallConfig: true, InstallSpec: true, InstallSystemd: true, ReloadSystemd: true}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}

	expectPaths := map[string]bool{
		filepath.Join(DefaultConfigDir, "svc", "a.conf"):     true,
		filepath.Join("/var/lib/globular/specs", "svc.yaml"): true,
		"/etc/systemd/system/svc.service":                    true,
	}
	for _, f := range plat.files {
		if !expectPaths[f.Path] {
			t.Fatalf("unexpected installed file %s", f.Path)
		}
		delete(expectPaths, f.Path)
	}
	if len(expectPaths) != 0 {
		t.Fatalf("missing installs: %v", expectPaths)
	}
	if sm.reloads != 1 {
		t.Fatalf("expected daemon-reload, got %d", sm.reloads)
	}
}

func TestInstallPackagePayloadCheckConverges(t *testing.T) {
	staging := t.TempDir()
	pkgJSON := `{"type":"service","name":"svc","version":"1.0.0","platform":"linux_amd64","entrypoint":"bin/svc","defaults":{"configDir":"config/svc","spec":"specs/svc.yaml"}}`
	mustWriteFile(t, filepath.Join(staging, "package.json"), []byte(pkgJSON))
	mustMkdir(t, filepath.Join(staging, "config", "svc"))
	mustWriteFile(t, filepath.Join(staging, "config", "svc", "a.conf"), []byte("cfg"))
	mustMkdir(t, filepath.Join(staging, "specs"))
	mustWriteFile(t, filepath.Join(staging, "specs", "svc.yaml"), []byte("spec"))
	mustMkdir(t, filepath.Join(staging, "systemd"))
	mustWriteFile(t, filepath.Join(staging, "systemd", "svc.service"), []byte("[Unit]\n"))

	prefix := filepath.Join(t.TempDir(), "prefix")
	cfgRoot := filepath.Join(t.TempDir(), "config")
	specRoot := filepath.Join(t.TempDir(), "specs")
	systemdRoot := filepath.Join(t.TempDir(), "systemd")

	mustMkdir(t, filepath.Join(prefix, "bin"))
	mustWriteFile(t, filepath.Join(prefix, "bin", "svc"), []byte("bin"))
	mustMkdir(t, filepath.Join(cfgRoot, "svc"))
	mustWriteFile(t, filepath.Join(cfgRoot, "svc", "a.conf"), []byte("cfg"))
	mustMkdir(t, specRoot)
	mustWriteFile(t, filepath.Join(specRoot, "svc.yaml"), []byte("spec"))
	mustMkdir(t, systemdRoot)
	mustWriteFile(t, filepath.Join(systemdRoot, "svc.service"), []byte("[Unit]\n"))

	ctx := &Context{
		StagingDir: staging,
		Prefix:     prefix,
		ConfigDir:  cfgRoot,
	}

	step := &InstallPackagePayloadStep{
		InstallBins:     true,
		InstallConfig:   true,
		InstallSpec:     true,
		InstallSystemd:  true,
		SpecDestRoot:    specRoot,
		SystemdDestRoot: systemdRoot,
	}

	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected status ok, got %v", status)
	}

	if err := os.Remove(filepath.Join(systemdRoot, "svc.service")); err != nil {
		t.Fatalf("remove systemd unit: %v", err)
	}

	status, err = step.Check(ctx)
	if err != nil {
		t.Fatalf("check after removal: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected needs-apply after removal, got %v", status)
	}
}

type reloadServiceManager struct{ reloads int }

func (r *reloadServiceManager) DaemonReload(ctx context.Context) error         { r.reloads++; return nil }
func (r *reloadServiceManager) Enable(ctx context.Context, name string) error  { return nil }
func (r *reloadServiceManager) Disable(ctx context.Context, name string) error { return nil }
func (r *reloadServiceManager) Start(ctx context.Context, name string) error   { return nil }
func (r *reloadServiceManager) Stop(ctx context.Context, name string) error    { return nil }
func (r *reloadServiceManager) Restart(ctx context.Context, name string) error { return nil }
func (r *reloadServiceManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	return platform.ServiceStatus{Name: name}, nil
}
func (r *reloadServiceManager) IsActive(ctx context.Context, name string) (bool, error) {
	return false, nil
}
func (r *reloadServiceManager) ResetFailed(ctx context.Context, name string) error { return nil }
func (r *reloadServiceManager) IsEnabled(ctx context.Context, name string) (bool, error) {
	return false, nil
}

func mustWriteFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}
