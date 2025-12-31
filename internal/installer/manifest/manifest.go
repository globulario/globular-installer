package manifest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Manifest stores installer state information for future upgrades or repairs.
type Manifest struct {
	SchemaVersion int               `json:"schemaVersion"`
	InstalledAt   time.Time         `json:"installedAt"`
	Version       string            `json:"version"`
	Prefix        string            `json:"prefix"`
	Files         map[string]string `json:"files"`
}

// DefaultPath returns the default manifest path inside the state directory.
// When stateDir is empty it defaults to /var/lib/globular.
func DefaultPath(stateDir string) string {
	if stateDir == "" {
		stateDir = "/var/lib/globular"
	}
	return filepath.Join(stateDir, "install-manifest.json")
}

// Load reads and parses the manifest at path.
// Returns os.ErrNotExist when the file does not exist.
func Load(path string) (*Manifest, error) {
	if path == "" {
		return nil, fmt.Errorf("manifest path is required")
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, os.ErrNotExist
		}
		return nil, err
	}
	defer f.Close()

	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()

	var m Manifest
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}

	if m.SchemaVersion == 0 {
		m.SchemaVersion = 1
	}
	if m.Files == nil {
		m.Files = make(map[string]string)
	}

	return &m, nil
}

// Save writes the manifest to path atomically.
func Save(path string, m *Manifest) error {
	if path == "" {
		return fmt.Errorf("manifest path is required")
	}
	if m == nil {
		return fmt.Errorf("manifest is nil")
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	temp, err := os.CreateTemp(dir, ".manifest-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	success := false
	defer func() {
		temp.Close()
		if !success {
			os.Remove(tempName)
		}
	}()

	enc := json.NewEncoder(temp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(m); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}

	if err := temp.Close(); err != nil {
		return err
	}

	if err := os.Rename(tempName, path); err != nil {
		return err
	}
	success = true

	if err := os.Chmod(path, 0o644); err != nil {
		return err
	}
	return nil
}

// New creates a manifest populated with the provided version and prefix.
func New(version, prefix string) *Manifest {
	return &Manifest{
		SchemaVersion: 1,
		InstalledAt:   time.Now().UTC(),
		Version:       version,
		Prefix:        prefix,
		Files:         make(map[string]string),
	}
}
