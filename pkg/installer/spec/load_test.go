package spec

import "testing"

func TestLoadInlineWithModeHandlesMissingKeys(t *testing.T) {
	specYAML := `version: 1
steps:
  - id: install-files
    type: install_files
    files:
      - path: /tmp/example
        owner: root
        group: root
        mode: 0644
        content: "{{.XDSConfigJSON}}"
`

	if _, err := LoadInlineWithMode(specYAML, map[string]string{}, true); err == nil {
		t.Fatalf("expected strict mode to fail when variable is absent")
	}

	if _, err := LoadInlineWithMode(specYAML, map[string]string{}, false); err != nil {
		t.Fatalf("expected permissive mode to succeed, got %v", err)
	}
}
