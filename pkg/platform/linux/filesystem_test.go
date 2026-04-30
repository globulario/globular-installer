package linux

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/pkg/platform"
)

func TestEnsureDirs_SharedRootStays0755(t *testing.T) {
	root := filepath.Join(t.TempDir(), "globular")
	// Register as shared root for the test.
	sharedRoots[root] = true
	t.Cleanup(func() { delete(sharedRoots, root) })

	// A spec declares the shared root as 0750 — the guard must force 0755.
	dirs := []platform.DirSpec{
		{Path: root, Owner: "", Group: "", Mode: 0o750},
	}
	if err := EnsureDirs(context.Background(), dirs); err != nil {
		t.Fatalf("EnsureDirs: %v", err)
	}

	info, err := os.Stat(root)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	got := info.Mode().Perm()
	if got&0o005 == 0 {
		t.Errorf("shared root mode = %o; want world-traversable (at least o+rx)", got)
	}
}

func TestEnsureDirs_PrivateSubdir0750Preserved(t *testing.T) {
	root := filepath.Join(t.TempDir(), "globular")
	sub := filepath.Join(root, "repository")

	sharedRoots[root] = true
	t.Cleanup(func() { delete(sharedRoots, root) })

	dirs := []platform.DirSpec{
		{Path: root, Owner: "", Group: "", Mode: 0o755},
		{Path: sub, Owner: "", Group: "", Mode: 0o750},
	}
	if err := EnsureDirs(context.Background(), dirs); err != nil {
		t.Fatalf("EnsureDirs: %v", err)
	}

	// Root must be 755.
	ri, _ := os.Stat(root)
	if ri.Mode().Perm() != 0o755 {
		t.Errorf("root mode = %o; want 0755", ri.Mode().Perm())
	}

	// Subdir must stay 0750.
	si, _ := os.Stat(sub)
	if si.Mode().Perm() != 0o750 {
		t.Errorf("subdir mode = %o; want 0750", si.Mode().Perm())
	}
}

func TestEnsureDirs_RepeatedInstallPreserves0755(t *testing.T) {
	root := filepath.Join(t.TempDir(), "globular")
	sharedRoots[root] = true
	t.Cleanup(func() { delete(sharedRoots, root) })

	dirs := []platform.DirSpec{
		{Path: root, Owner: "", Group: "", Mode: 0o750},
	}

	// Simulate 3 package installs — each calls EnsureDirs.
	for i := 0; i < 3; i++ {
		if err := EnsureDirs(context.Background(), dirs); err != nil {
			t.Fatalf("EnsureDirs (iteration %d): %v", i, err)
		}
		info, _ := os.Stat(root)
		if info.Mode().Perm()&0o005 == 0 {
			t.Fatalf("iteration %d: shared root lost world-traversable (mode=%o)", i, info.Mode().Perm())
		}
	}
}
