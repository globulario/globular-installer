package installer

import (
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/pkg/installer/spec"
)

func TestBuildUninstallPlanFromEnvoySpec(t *testing.T) {
	vars := map[string]string{
		"Prefix":    DefaultPrefix,
		"StateDir":  DefaultStateDir,
		"ConfigDir": DefaultConfigDir,
		"LogDir":    DefaultLogDir,
		"Version":   "0.0.0",
	}
	sp, err := spec.Load(filepath.Join("..", "..", "internal", "specs", "envoy_service.yaml"), vars)
	if err != nil {
		t.Fatalf("load spec: %v", err)
	}
	ctx := &Context{
		Prefix:    vars["Prefix"],
		StateDir:  vars["StateDir"],
		ConfigDir: vars["ConfigDir"],
		LogDir:    vars["LogDir"],
		Version:   vars["Version"],
		Ports:     mustPortAllocatorForTest(),
	}
	plan, err := BuildUninstallPlan(ctx, sp)
	if err != nil {
		t.Fatalf("build uninstall plan: %v", err)
	}
	if plan.Name != "uninstall" {
		t.Fatalf("unexpected plan name %q", plan.Name)
	}
	if len(plan.Steps) != 3 {
		t.Fatalf("expected 3 steps, got %d", len(plan.Steps))
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

	uninstallBins, ok := plan.Steps[2].(*UninstallBinariesStep)
	if !ok {
		t.Fatalf("step 2 is %T", plan.Steps[2])
	}
	expectedBin := filepath.Join(vars["Prefix"], "bin", "envoy")
	if len(uninstallBins.Paths) != 1 || uninstallBins.Paths[0] != expectedBin {
		t.Fatalf("expected bin %q, got %v", expectedBin, uninstallBins.Paths)
	}
}

func mustPortAllocatorForTest() *PortAllocator {
	pa, err := NewPortAllocator(10000, 10100)
	if err != nil {
		panic(err)
	}
	return pa
}

func TestRbacSpecIncludesPayloadBeforeService(t *testing.T) {
	vars := map[string]string{
		"Prefix":    DefaultPrefix,
		"StateDir":  DefaultStateDir,
		"ConfigDir": DefaultConfigDir,
		"LogDir":    DefaultLogDir,
		"Version":   "0.0.0",
	}
	sp, err := spec.Load(filepath.Join("..", "..", "internal", "specs", "rbac_service.yaml"), vars)
	if err != nil {
		t.Fatalf("load spec: %v", err)
	}
	steps := sp.Steps
	find := func(id string) int {
		for i, st := range steps {
			if st.ID == id {
				return i
			}
		}
		return -1
	}
	payloadIdx := find("install-rbac-binary")
	configIdx := find("ensure-rbac-config")
	serviceIdx := find("install-rbac-service")
	if payloadIdx == -1 || serviceIdx == -1 || configIdx == -1 {
		t.Fatalf("missing expected steps: payload=%d config=%d service=%d", payloadIdx, configIdx, serviceIdx)
	}
	if !(payloadIdx < configIdx && configIdx < serviceIdx) {
		t.Fatalf("expected payload < config < service, got %d < %d < %d", payloadIdx, configIdx, serviceIdx)
	}
}
