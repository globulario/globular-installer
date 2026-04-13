package installer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunScriptStepRequired(t *testing.T) {
	t.Run("required script missing returns error from Check", func(t *testing.T) {
		staging := t.TempDir()
		os.MkdirAll(filepath.Join(staging, "scripts"), 0o755)

		step := NewRunScriptStep("missing.sh", 0)
		step.Required = true

		ctx := &Context{StagingDir: staging}
		status, err := step.Check(ctx)
		if err == nil {
			t.Fatal("expected error for missing required script")
		}
		if status != StatusUnknown {
			t.Fatalf("expected StatusUnknown, got %v", status)
		}
	})

	t.Run("optional script missing returns StatusSkipped from Check", func(t *testing.T) {
		staging := t.TempDir()
		os.MkdirAll(filepath.Join(staging, "scripts"), 0o755)

		step := NewRunScriptStep("missing.sh", 0)
		// Required defaults to false

		ctx := &Context{StagingDir: staging}
		status, err := step.Check(ctx)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if status != StatusSkipped {
			t.Fatalf("expected StatusSkipped, got %v", status)
		}
	})

	t.Run("required script present returns StatusNeedsApply", func(t *testing.T) {
		staging := t.TempDir()
		scriptsDir := filepath.Join(staging, "scripts")
		os.MkdirAll(scriptsDir, 0o755)
		os.WriteFile(filepath.Join(scriptsDir, "post-install.sh"), []byte("#!/bin/bash\necho ok"), 0o755)

		step := NewRunScriptStep("post-install.sh", 0)
		step.Required = true

		ctx := &Context{StagingDir: staging}
		status, err := step.Check(ctx)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if status != StatusNeedsApply {
			t.Fatalf("expected StatusNeedsApply, got %v", status)
		}
	})

	t.Run("required script missing returns error from Apply", func(t *testing.T) {
		staging := t.TempDir()
		os.MkdirAll(filepath.Join(staging, "scripts"), 0o755)

		step := NewRunScriptStep("missing.sh", 0)
		step.Required = true

		ctx := &Context{StagingDir: staging}
		err := step.Apply(ctx)
		if err == nil {
			t.Fatal("expected error for missing required script in Apply")
		}
	})

	t.Run("optional script missing returns nil from Apply", func(t *testing.T) {
		staging := t.TempDir()
		os.MkdirAll(filepath.Join(staging, "scripts"), 0o755)

		step := NewRunScriptStep("missing.sh", 0)

		ctx := &Context{StagingDir: staging}
		err := step.Apply(ctx)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}
