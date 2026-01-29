package installer

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/internal/installer/spec"
)

func TestDeriveInstallArtifacts(t *testing.T) {
	root := t.TempDir()

	writeTestFile(t, filepath.Join(root, "bin", "foo"), []byte("bin"))
	writeTestFile(t, filepath.Join(root, "config", "app", "cfg.yaml"), []byte("cfg"))
	writeTestFile(t, filepath.Join(root, "state", "data.txt"), []byte("state"))
	writeTestFile(t, filepath.Join(root, "assets", "a.txt"), []byte("asset"))
	writeTestFile(t, filepath.Join(root, "systemd", "foo.service"), []byte("[Unit]\n"))

	files, units, services, err := deriveInstallArtifacts(root, "/opt/glob", "/etc/glob", "/var/glob")
	if err != nil {
		t.Fatalf("derive: %v", err)
	}

	expectPaths := map[string]bool{
		"/opt/glob/bin/foo":               false,
		"/var/glob/app/cfg.yaml":          false,
		"/var/glob/data.txt":              false,
		"/opt/glob/assets/a.txt":          false,
		"/etc/systemd/system/foo.service": true,
	}
	if len(units) != 1 {
		t.Fatalf("expected 1 unit, got %d", len(units))
	}
	if units[0].Path != "/etc/systemd/system/foo.service" {
		t.Fatalf("unit path mismatch: %s", units[0].Path)
	}
	if len(services) != 1 || services[0] != "foo.service" {
		t.Fatalf("service names mismatch: %v", services)
	}
	for _, f := range files {
		if _, ok := expectPaths[f.Path]; !ok {
			t.Fatalf("unexpected file path %s", f.Path)
		}
		expectPaths[f.Path] = true
	}
	for path, seen := range expectPaths {
		if !seen {
			t.Fatalf("missing derived path %s", path)
		}
	}
}

func TestBuildInstallPlanWithDerivedDefaultSpec(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "bin", "foo"), []byte("bin"))
	writeTestFile(t, filepath.Join(root, "systemd", "foo.service"), []byte("[Unit]\n"))

	ctx := &Context{
		Prefix:     "/opt/glob",
		ConfigDir:  "/etc/glob",
		StateDir:   "/var/glob",
		StagingDir: root,
	}
	sp := spec.DefaultInstallSpec(nil)

	plan, err := BuildInstallPlan(ctx, sp)
	if err != nil {
		t.Fatalf("build plan: %v", err)
	}
	if len(plan.Steps) == 0 {
		t.Fatalf("expected steps in plan")
	}
}

func writeTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
