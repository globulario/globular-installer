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

func TestEnsureServiceConfig_CheckNeedsApplyWhenMissing(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-1", "localhost:20000")

	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
	}
	step := &EnsureServiceConfigStep{
		ServiceName:         "svc",
		Exec:                bin,
		RewriteIfOutOfRange: true,
	}

	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected needs apply, got %v", status)
	}
}

func TestEnsureServiceConfig_ApplyWritesConfigInRange(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-2", "localhost:20000")
	fp := &configPlatform{}

	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
		Platform:  fp,
		Runtime:   &RuntimeState{ChangedFiles: map[string]bool{}},
	}

	step := &EnsureServiceConfigStep{
		ServiceName:         "svc",
		Exec:                bin,
		RewriteIfOutOfRange: true,
	}

	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}

	if len(fp.files) != 1 {
		t.Fatalf("expected 1 file written, got %d", len(fp.files))
	}
	got := fp.files[0]
	if filepath.Base(got.Path) != "svc-2.json" {
		t.Fatalf("unexpected config path %s", got.Path)
	}
	var cfg map[string]any
	if err := json.Unmarshal(got.Data, &cfg); err != nil {
		t.Fatalf("parse written json: %v", err)
	}
	port := int(cfg["Port"].(float64))
	if port < 55000 || port > 55010 {
		t.Fatalf("port out of range: %d", port)
	}
}

func TestEnsureServiceConfig_CheckDetectsOutOfRange(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-3", "localhost:20000")
	writeJSONConfig(t, filepath.Join(root, "svc-3.json"), map[string]any{
		"Address": "localhost:30000",
		"Port":    30000,
	})

	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
	}
	step := &EnsureServiceConfigStep{
		Exec:                bin,
		RewriteIfOutOfRange: true,
	}

	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected needs apply, got %v", status)
	}
}

func TestEnsureServiceConfig_CheckOKWhenInRange(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-4", "localhost:20000")
	writeJSONConfig(t, filepath.Join(root, "svc-4.json"), map[string]any{
		"Address": "localhost:55002",
		"Port":    55002,
	})

	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
	}
	step := &EnsureServiceConfigStep{
		Exec:                bin,
		RewriteIfOutOfRange: true,
	}

	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected ok, got %v", status)
	}
}

func TestEnsureServiceConfig_CheckDescribeFailureIsOK(t *testing.T) {
	root := t.TempDir()
	bin := makeFailBinaryEsc(t, root, 2)
	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
	}
	step := &EnsureServiceConfigStep{Exec: bin}
	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected ok, got %v", status)
	}
}

func TestEnsureServiceConfig_ApplyKeepsExistingInRange(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-keep", "localhost:20000")
	cfg := filepath.Join(root, "svc-keep.json")
	writeJSONConfig(t, cfg, map[string]any{
		"Address": "localhost:55003",
		"Port":    55003,
		"Foo":     "bar",
	})
	fp := &configPlatform{}
	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 55000, 55010),
		Platform:  fp,
	}
	step := &EnsureServiceConfigStep{Exec: bin, RewriteIfOutOfRange: true}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	data, _ := os.ReadFile(cfg)
	var out map[string]any
	json.Unmarshal(data, &out)
	if out["Foo"] != "bar" || int(out["Port"].(float64)) != 55003 {
		t.Fatalf("config was modified unexpectedly: %v", out)
	}
	if len(fp.files) != 0 {
		t.Fatalf("expected no writes, got %d", len(fp.files))
	}
}

func TestEnsureServiceConfig_ApplyRewritesOnlyAddressPort(t *testing.T) {
	root := t.TempDir()
	bin := makeFakeDescribeBinary(t, root, "svc-fix", "localhost:20000")
	cfg := filepath.Join(root, "svc-fix.json")
	writeJSONConfig(t, cfg, map[string]any{
		"Address": "localhost:9999",
		"Port":    9999,
		"Foo":     "bar",
		"Bar":     123,
	})
	fp := &configPlatform{}
	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 10000, 10100),
		Platform:  fp,
	}
	step := &EnsureServiceConfigStep{Exec: bin, RewriteIfOutOfRange: true, AddressHost: "localhost"}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if len(fp.files) != 1 {
		t.Fatalf("expected one write")
	}
	var out map[string]any
	json.Unmarshal(fp.files[0].Data, &out)
	if out["Foo"] != "bar" || int(out["Bar"].(float64)) != 123 {
		t.Fatalf("unexpected field changes: %v", out)
	}
	port := int(out["Port"].(float64))
	if port < 10000 || port > 10100 || out["Address"] == "localhost:9999" {
		t.Fatalf("port not rewritten: %v", out)
	}
}

func TestEnsureServiceConfig_ApplyDescribeFailureNoConfigDoesNothing(t *testing.T) {
	root := t.TempDir()
	bin := makeFailBinaryEsc(t, root, 2)
	ctx := &Context{
		Prefix:    root,
		ConfigDir: root,
		Ports:     mustPortAllocator(t, 10000, 10100),
		Platform:  &configPlatform{},
	}
	step := &EnsureServiceConfigStep{Exec: bin}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	entries, _ := os.ReadDir(root)
	for _, e := range entries {
		if e.Name() != "fail.sh" {
			t.Fatalf("unexpected file created: %s", e.Name())
		}
	}
}

// Helpers

func makeFakeDescribeBinary(t *testing.T, dir, id, addr string) string {
	t.Helper()
	path := filepath.Join(dir, id+"-bin.sh")
	content := "#!/bin/sh\n" +
		"echo '{\"Id\":\"" + id + "\",\"Address\":\"" + addr + "\"}'\n"
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write fake bin: %v", err)
	}
	return path
}

func writeJSONConfig(t *testing.T, path string, cfg map[string]any) {
	t.Helper()
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
}

func mustPortAllocator(t *testing.T, start, end int) *PortAllocator {
	t.Helper()
	pa, err := NewPortAllocator(start, end)
	if err != nil {
		t.Fatalf("new allocator: %v", err)
	}
	return pa
}

type configPlatform struct {
	files []platform.FileSpec
}

func (p *configPlatform) Name() string { return "fake" }
func (p *configPlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (p *configPlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error { return nil }
func (p *configPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	p.files = append(p.files, files...)
	return nil
}
func (p *configPlatform) ServiceManager() platform.ServiceManager { return nil }

func makeFailBinaryEsc(t *testing.T, dir string, exitCode int) string {
	t.Helper()
	path := filepath.Join(dir, "fail.sh")
	content := "#!/bin/sh\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write fail bin: %v", err)
	}
	return path
}
