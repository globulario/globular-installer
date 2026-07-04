package installer

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestRunScriptStepPassesScriptEnv verifies that Context.ScriptEnv entries are
// exported to the executed script's environment — the wiring that lets a Day-1
// join pass SCYLLA_INSTALL_INTENT=fresh-join to the ScyllaDB post-install.
func TestRunScriptStepPassesScriptEnv(t *testing.T) {
	staging := t.TempDir()
	stateDir := t.TempDir()
	scriptsDir := filepath.Join(staging, "scripts")
	if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	outFile := filepath.Join(stateDir, "intent.out")
	script := "#!/usr/bin/env bash\nprintf '%s' \"$SCYLLA_INSTALL_INTENT\" > \"" + outFile + "\"\n"
	if err := os.WriteFile(filepath.Join(scriptsDir, "probe.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	step := NewRunScriptStep("probe.sh", 30*time.Second)
	step.Required = true
	ctx := &Context{
		StagingDir:   staging,
		StateDir:     stateDir,
		TemplateVars: map[string]string{"NodeIP": "10.0.0.1"},
		ScriptEnv:    map[string]string{"SCYLLA_INSTALL_INTENT": "fresh-join"},
	}

	if err := step.Apply(ctx); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	got, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("read probe output: %v", err)
	}
	if string(got) != "fresh-join" {
		t.Errorf("script saw SCYLLA_INSTALL_INTENT=%q, want fresh-join", string(got))
	}
}
