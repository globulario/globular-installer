package installer

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/globulario/globular-installer/internal/installer/spec"
	"github.com/globulario/globular-installer/internal/platform"
)

func TestTemplateVarsIncludeLogDir(t *testing.T) {
	platform.RegisterLinuxPlatform(func() platform.Platform { return &noopPlatform{} })
	root := t.TempDir()
	prefix := filepath.Join(root, "opt")
	state := filepath.Join(root, "state")
	config := filepath.Join(root, "etc")
	logdir := filepath.Join(root, "log")
	for _, d := range []string{prefix, state, config, logdir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}
	ctx, err := NewContext(Options{
		Prefix:    prefix,
		StateDir:  state,
		ConfigDir: config,
		LogDir:    logdir,
	})
	if err != nil {
		t.Fatalf("new context: %v", err)
	}
	if ctx.TemplateVars["LogDir"] != logdir {
		t.Fatalf("expected LogDir template var %s, got %s", logdir, ctx.TemplateVars["LogDir"])
	}
	specYAML := `version: 1
steps:
  - id: ensure-dirs
    type: ensure_dirs
    dirs:
      - path: "{{.LogDir}}/svc"`
	sp, err := spec.LoadInlineWithMode(specYAML, ctx.TemplateVars, true)
	if err != nil {
		t.Fatalf("load spec with logdir: %v", err)
	}
	if len(sp.Steps) != 1 {
		t.Fatalf("expected 1 step")
	}
	dirList, ok := sp.Steps[0].Params["dirs"].([]any)
	if !ok || len(dirList) != 1 {
		t.Fatalf("expected dirs list")
	}
	dirMap, ok := dirList[0].(map[string]any)
	if !ok {
		t.Fatalf("expected dir map")
	}
	if dirMap["path"] != logdir+"/svc" {
		t.Fatalf("expected rendered log dir path, got %v", dirMap["path"])
	}
}

type noopPlatform struct{}

func (n *noopPlatform) Name() string { return "noop" }
func (n *noopPlatform) EnsureUserGroup(ctx context.Context, user platform.UserSpec, group platform.GroupSpec) error {
	return nil
}
func (n *noopPlatform) EnsureDirs(ctx context.Context, dirs []platform.DirSpec) error { return nil }
func (n *noopPlatform) InstallFiles(ctx context.Context, files []platform.FileSpec) error {
	return nil
}
func (n *noopPlatform) ServiceManager() platform.ServiceManager { return nil }
