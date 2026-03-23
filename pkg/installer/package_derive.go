package installer

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"text/template"

	"github.com/globulario/globular-installer/pkg/platform"
)

func deriveInstallArtifacts(root, prefix, configDir, stateDir string) ([]platform.FileSpec, []platform.FileSpec, []string, error) {
	files := []platform.FileSpec{}
	units := []platform.FileSpec{}
	services := []string{}

	if root == "" {
		return files, units, services, nil
	}
	if prefix == "" {
		prefix = DefaultPrefix
	}
	if configDir == "" {
		configDir = DefaultConfigDir
	}
	if stateDir == "" {
		stateDir = DefaultStateDir
	}

	// bin/
	binDir := filepath.Join(root, "bin")
	if entries, err := os.ReadDir(binDir); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			src := filepath.Join(binDir, entry.Name())
			data, err := os.ReadFile(src)
			if err != nil {
				return nil, nil, nil, fmt.Errorf("read bin %s: %w", src, err)
			}
			files = append(files, platform.FileSpec{
				Path:   filepath.Join(prefix, "bin", entry.Name()),
				Data:   data,
				Owner:  "root",
				Group:  "root",
				Mode:   0o755,
				Atomic: true,
			})
		}
	}

	// config/
	// For config/, install each subdirectory to stateDir/{subdir}
	// e.g., config/etcd/ -> /var/lib/globular/etcd/
	//       config/minio/ -> /var/lib/globular/minio/
	cfgDir := filepath.Join(root, "config")
	if entries, err := os.ReadDir(cfgDir); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			srcPath := filepath.Join(cfgDir, entry.Name())
			destPath := filepath.Join(stateDir, entry.Name())
			if cfgFiles, err := collectPayloadFiles(srcPath, destPath, 0o644); err != nil {
				return nil, nil, nil, err
			} else if len(cfgFiles) > 0 {
				files = append(files, cfgFiles...)
			}
		}
	}

	// state/
	stateSrc := filepath.Join(root, "state")
	if stateFiles, err := collectPayloadFiles(stateSrc, stateDir, 0o644); err != nil {
		return nil, nil, nil, err
	} else if len(stateFiles) > 0 {
		files = append(files, stateFiles...)
	}

	// assets/
	assetsSrc := filepath.Join(root, "assets")
	if assetsFiles, err := collectPayloadFiles(assetsSrc, filepath.Join(prefix, "assets"), 0o644); err != nil {
		return nil, nil, nil, err
	} else if len(assetsFiles) > 0 {
		files = append(files, assetsFiles...)
	}

	// systemd units
	systemdDir := filepath.Join(root, "systemd")
	if entries, err := os.ReadDir(systemdDir); err == nil {
		templateVars := map[string]string{
			"Prefix":    prefix,
			"ConfigDir": configDir,
			"StateDir":  stateDir,
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			name := entry.Name()
			if !strings.HasSuffix(name, ".service") {
				continue
			}
			src := filepath.Join(systemdDir, name)
			raw, err := os.ReadFile(src)
			if err != nil {
				return nil, nil, nil, fmt.Errorf("read systemd %s: %w", src, err)
			}
			rendered, err := renderTemplateString(string(raw), templateVars)
			if err != nil {
				return nil, nil, nil, fmt.Errorf("render systemd %s: %w", src, err)
			}
			if strings.Contains(rendered, "{{") {
				return nil, nil, nil, fmt.Errorf("systemd unit %s contains unresolved template placeholders", src)
			}
			units = append(units, platform.FileSpec{
				Path:   filepath.Join("/etc/systemd/system", name),
				Data:   []byte(rendered),
				Owner:  "root",
				Group:  "root",
				Mode:   0o644,
				Atomic: true,
			})
			services = append(services, name)
		}
	}

	return files, units, services, nil
}

func collectPayloadFiles(srcRoot, destRoot string, mode fs.FileMode) ([]platform.FileSpec, error) {
	specs := []platform.FileSpec{}
	info, err := os.Stat(srcRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return specs, nil
		}
		return nil, err
	}
	if !info.IsDir() {
		return specs, nil
	}
	err = filepath.WalkDir(srcRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		specs = append(specs, platform.FileSpec{
			Path:   filepath.Join(destRoot, rel),
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   mode,
			Atomic: true,
		})
		return nil
	})
	return specs, err
}

func renderTemplateString(input string, vars map[string]string) (string, error) {
	tmpl, err := template.New("").Option("missingkey=error").Parse(input)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, vars); err != nil {
		return "", err
	}
	return buf.String(), nil
}
