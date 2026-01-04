package installer

import (
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/internal/installer/spec"
)

func TestBuildUninstallPlanFromEnvoySpec(t *testing.T) {
	vars := map[string]string{
		"Prefix":    DefaultPrefix,
		"StateDir":  DefaultStateDir,
		"ConfigDir": DefaultConfigDir,
		"Version":   "0.0.0",
	}
	sp, err := spec.Load(filepath.Join("..", "specs", "envoy_service.yaml"), vars)
	if err != nil {
		t.Fatalf("load spec: %v", err)
	}
	ctx := &Context{
		Prefix:    vars["Prefix"],
		StateDir:  vars["StateDir"],
		ConfigDir: vars["ConfigDir"],
		Version:   vars["Version"],
	}
	plan, err := BuildUninstallPlan(ctx, sp)
	if err != nil {
		t.Fatalf("build uninstall plan: %v", err)
	}
	if plan.Name != "uninstall" {
		t.Fatalf("unexpected plan name %q", plan.Name)
	}
	if len(plan.Steps) != 4 {
		t.Fatalf("expected 4 steps, got %d", len(plan.Steps))
	}

	stopStep, ok := plan.Steps[0].(*StopServicesStep)
	if !ok {
		t.Fatalf("step 0 is %T", plan.Steps[0])
	}
	if len(stopStep.Services) != 1 || stopStep.Services[0] != "globular-envoy.service" {
		t.Fatalf("unexpected services %v", stopStep.Services)
	}

	uninstallSvc, ok := plan.Steps[1].(*UninstallServicesStep)
	if !ok {
		t.Fatalf("step 1 is %T", plan.Steps[1])
	}
	expectedUnit := filepath.Join("/etc/systemd/system", "globular-envoy.service")
	if len(uninstallSvc.Units) != 1 || uninstallSvc.Units[0].Path != expectedUnit {
		t.Fatalf("expected unit %q, got %v", expectedUnit, uninstallSvc.Units)
	}

	uninstallFiles, ok := plan.Steps[2].(*UninstallFilesStep)
	if !ok {
		t.Fatalf("step 2 is %T", plan.Steps[2])
	}
	expectedFile := filepath.Join(vars["ConfigDir"], "envoy", "envoy.yaml")
	if len(uninstallFiles.Files) != 1 || uninstallFiles.Files[0].Path != expectedFile {
		t.Fatalf("expected file %q, got %v", expectedFile, uninstallFiles.Files)
	}

	uninstallBins, ok := plan.Steps[3].(*UninstallBinariesStep)
	if !ok {
		t.Fatalf("step 3 is %T", plan.Steps[3])
	}
	expectedBin := filepath.Join(vars["Prefix"], "bin", "envoy")
	if len(uninstallBins.Paths) != 1 || uninstallBins.Paths[0] != expectedBin {
		t.Fatalf("expected bin %q, got %v", expectedBin, uninstallBins.Paths)
	}
}
