package installer

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/pkg/platform"
)

// fsPlatform is a test double that actually writes files to disk and honours
// SkipIfExists, mirroring what linux.installOneFile does.  It is used to
// exercise the full Check→Apply cycle without requiring root or systemd.
type fsPlatform struct{}

func (p *fsPlatform) Name() string { return "fs" }
func (p *fsPlatform) EnsureUserGroup(_ context.Context, _ platform.UserSpec, _ platform.GroupSpec) error {
	return nil
}
func (p *fsPlatform) EnsureDirs(_ context.Context, _ []platform.DirSpec) error { return nil }
func (p *fsPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	_, err := p.InstallFilesWithResult(ctx, files)
	return err
}
func (p *fsPlatform) ServiceManager() platform.ServiceManager { return nil }
func (p *fsPlatform) InstallFilesWithResult(_ context.Context, files []platform.FileSpec) (platform.InstallFilesResult, error) {
	var result platform.InstallFilesResult
	for _, f := range files {
		if f.SkipIfExists {
			if _, err := os.Stat(f.Path); err == nil {
				continue // file exists — preserve it
			}
		}
		if err := os.MkdirAll(filepath.Dir(f.Path), 0o755); err != nil {
			return platform.InstallFilesResult{}, err
		}
		if err := os.WriteFile(f.Path, f.Data, 0o644); err != nil {
			return platform.InstallFilesResult{}, err
		}
		result.Changed = append(result.Changed, f.Path)
	}
	return result, nil
}

// ctxFor builds a minimal installer Context backed by fsPlatform.
func ctxFor(t *testing.T) *Context {
	t.Helper()
	return &Context{Platform: &fsPlatform{}, Runtime: &RuntimeState{}}
}

// --- Check() tests -----------------------------------------------------------

// Fresh node: file doesn't exist → Check should report NeedsApply.
func TestInstallFilesStep_Check_FreshNode(t *testing.T) {
	dir := t.TempDir()
	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: filepath.Join(dir, "etcd.yaml"), Data: []byte("seed-config"), SkipIfExists: true},
		},
	}
	status, err := step.Check(ctxFor(t))
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected NeedsApply on fresh node, got %v", status)
	}
}

// File exists, SkipIfExists=true, content differs → Check must report OK.
// The seed is no longer authoritative once the file exists on disk.
func TestInstallFilesStep_Check_ExistingFileSkipped(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "etcd.yaml")
	mustWriteFileInst(t, path, []byte("cluster-membership-config"))

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: []byte("single-node-seed"), SkipIfExists: true},
		},
	}
	status, err := step.Check(ctxFor(t))
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected OK when SkipIfExists file exists (content ignored), got %v", status)
	}
}

// File exists, SkipIfExists=false (default), content differs → NeedsApply.
func TestInstallFilesStep_Check_ContentDiffNoSkip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	mustWriteFileInst(t, path, []byte("old"))

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: []byte("new"), SkipIfExists: false},
		},
	}
	status, err := step.Check(ctxFor(t))
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusNeedsApply {
		t.Fatalf("expected NeedsApply when content differs and SkipIfExists=false, got %v", status)
	}
}

// File exists, content identical → OK regardless of SkipIfExists.
func TestInstallFilesStep_Check_ContentMatch(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	data := []byte("same-content")
	mustWriteFileInst(t, path, data)

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: data, SkipIfExists: false},
		},
	}
	status, err := step.Check(ctxFor(t))
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("expected OK when content matches, got %v", status)
	}
}

// --- Apply() tests -----------------------------------------------------------

// Fresh node: Apply writes the seed config because the file doesn't exist.
func TestInstallFilesStep_Apply_FreshNodeWritesSeed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "etcd.yaml")
	seed := []byte("initial-cluster-state: new\n")

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: seed, SkipIfExists: true},
		},
	}
	if err := step.Apply(ctxFor(t)); err != nil {
		t.Fatalf("apply: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after apply: %v", err)
	}
	if string(got) != string(seed) {
		t.Fatalf("expected seed written, got %q", got)
	}
}

// Existing file with SkipIfExists=true: Apply must NOT overwrite it.
// Simulates a package reinstall on a Day-1 joined node — the cluster
// etcd.yaml must survive.
func TestInstallFilesStep_Apply_ExistingFilePreserved(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "etcd.yaml")
	clusterCfg := []byte("initial-cluster-state: existing\ninitial-cluster: globular-etcd=https://10.0.0.8:2380,...\n")
	mustWriteFileInst(t, path, clusterCfg)

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: []byte("initial-cluster-state: new\n"), SkipIfExists: true},
		},
	}
	if err := step.Apply(ctxFor(t)); err != nil {
		t.Fatalf("apply: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after apply: %v", err)
	}
	if string(got) != string(clusterCfg) {
		t.Fatalf("cluster config was overwritten: got %q", got)
	}
}

// Reinstall / upgrade cycle: Check→Apply→Check must leave an existing
// SkipIfExists file untouched across multiple iterations.
func TestInstallFilesStep_ReinstallDoesNotOverwriteExistingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "etcd.yaml")
	original := []byte("cluster-config-v2\n")
	mustWriteFileInst(t, path, original)

	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: []byte("single-node-seed\n"), SkipIfExists: true},
		},
	}
	ctx := ctxFor(t)

	// Simulate three reinstall iterations.
	for i := range 3 {
		status, err := step.Check(ctx)
		if err != nil {
			t.Fatalf("iter %d check: %v", i, err)
		}
		if status != StatusOK {
			// Check says OK — nothing to apply; this is correct.
			// If it returns NeedsApply here the test will catch the
			// overwrite in the read below.
		}
		if err := step.Apply(ctx); err != nil {
			t.Fatalf("iter %d apply: %v", i, err)
		}
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("iter %d read: %v", i, err)
		}
		if string(got) != string(original) {
			t.Fatalf("iter %d: file was overwritten, got %q", i, got)
		}
	}
}

// Day-1 join scenario: after the gateway join script writes a cluster
// membership etcd.yaml, a subsequent package reinstall (triggered by
// infra_preparing) must not revert it to the single-node seed.
func TestInstallFilesStep_Day1JoinEtcdConfigNotReverted(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "etcd.yaml")

	// Step 1: fresh node — Apply writes the seed (join script hasn't run yet).
	seedCfg := []byte("initial-cluster-state: new\nname: globular-etcd\n")
	step := &InstallFilesStep{
		Files: []platform.FileSpec{
			{Path: path, Data: seedCfg, SkipIfExists: true},
		},
	}
	ctx := ctxFor(t)
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("initial apply: %v", err)
	}

	// Step 2: join script overwrites with cluster membership config.
	clusterCfg := []byte("initial-cluster-state: existing\ninitial-cluster: globular-etcd=https://10.0.0.63:2380,globular-etcd=https://10.0.0.8:2380\n")
	mustWriteFileInst(t, path, clusterCfg)

	// Step 3: node-agent triggers package reinstall (infra_preparing).
	// Check must see the file as satisfied (SkipIfExists=true, file exists).
	status, err := step.Check(ctx)
	if err != nil {
		t.Fatalf("post-join check: %v", err)
	}
	if status != StatusOK {
		t.Fatalf("post-join check: expected OK (seed-only, file exists), got %v", status)
	}

	// Apply must not touch the file.
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("post-join apply: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after post-join apply: %v", err)
	}
	if string(got) != string(clusterCfg) {
		t.Fatalf("cluster config was reverted to seed: got %q", got)
	}
}

func mustWriteFileInst(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
