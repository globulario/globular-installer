package installer

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestEmbeddedSpecsUseHyphenatedStateDirs(t *testing.T) {
	specRoot := filepath.Join("..", "..", "internal", "packagecatalog", "specs")
	entries, err := os.ReadDir(specRoot)
	if err != nil {
		t.Fatalf("read embedded specs: %v", err)
	}

	pat := regexp.MustCompile(`\{\{\.StateDir\}\}/([A-Za-z0-9_-]+)`)
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".yaml" {
			continue
		}
		path := filepath.Join(specRoot, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		for _, m := range pat.FindAllStringSubmatch(string(data), -1) {
			top := m[1]
			switch top {
			case "services", "pki", "config":
				continue
			}
			if regexp.MustCompile(`_`).MatchString(top) {
				t.Errorf("%s uses underscore state dir %q", path, top)
			}
		}
	}
}
