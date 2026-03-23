package installer

import (
	"archive/tar"
	"compress/gzip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestStagePackageRejectsTraversal(t *testing.T) {
	tgz := filepath.Join(t.TempDir(), "bad.tgz")
	if err := writeTarGz(tgz, []tarEntry{{Name: "../evil", Data: []byte("x")}}); err != nil {
		t.Fatalf("write tgz: %v", err)
	}
	step := &StagePackageStep{Path: tgz, StagingRoot: t.TempDir(), RequirePlatformMatch: true, RequireTypeService: true}
	ctx := &Context{}
	if err := step.Apply(ctx); err == nil {
		t.Fatalf("expected error for traversal")
	}
}

func TestStagePackagePlatformMismatch(t *testing.T) {
	tgz := filepath.Join(t.TempDir(), "pkg.tgz")
	manifest := `{"type":"service","name":"svc","version":"1.0.0","platform":"other_arch","defaults":{"configDir":"config/svc","spec":"specs/svc.yaml"}}`
	entries := []tarEntry{
		{Name: "package.json", Data: []byte(manifest)},
	}
	if err := writeTarGz(tgz, entries); err != nil {
		t.Fatalf("write tgz: %v", err)
	}
	step := &StagePackageStep{Path: tgz, StagingRoot: t.TempDir(), RequirePlatformMatch: true, RequireTypeService: true}
	ctx := &Context{}
	if err := step.Apply(ctx); err == nil {
		t.Fatalf("expected platform mismatch error")
	}
}

func TestStagePackageSuccess(t *testing.T) {
	tgz := filepath.Join(t.TempDir(), "pkg.tgz")
	manifest := `{"type":"service","name":"svc","version":"1.0.0","platform":"` + runtime.GOOS + `_` + runtime.GOARCH + `","defaults":{"configDir":"config/svc","spec":"specs/svc.yaml"}}`
	entries := []tarEntry{
		{Name: "package.json", Data: []byte(manifest)},
		{Name: "config/svc/a.conf", Data: []byte("x")},
		{Name: "specs/svc.yaml", Data: []byte("spec")},
	}
	if err := writeTarGz(tgz, entries); err != nil {
		t.Fatalf("write tgz: %v", err)
	}
	stageRoot := t.TempDir()
	step := &StagePackageStep{Path: tgz, StagingRoot: stageRoot, RequirePlatformMatch: true, RequireTypeService: true}
	ctx := &Context{Runtime: &RuntimeState{}}
	if err := step.Apply(ctx); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if ctx.StagingDir == "" {
		t.Fatalf("staging dir not set")
	}
	if ctx.Runtime.StagedPackagePath != tgz {
		t.Fatalf("runtime not populated")
	}
}

// helper

type tarEntry struct {
	Name string
	Data []byte
}

func writeTarGz(path string, entries []tarEntry) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()
	for _, e := range entries {
		hdr := &tar.Header{Name: e.Name, Mode: 0o644, Size: int64(len(e.Data))}
		if len(e.Data) == 0 {
			hdr.Typeflag = tar.TypeDir
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if len(e.Data) > 0 {
			if _, err := tw.Write(e.Data); err != nil {
				return err
			}
		}
	}
	return nil
}
