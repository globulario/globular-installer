package spec

import (
	"bytes"
	"fmt"
	"os"
	"text/template"

	"gopkg.in/yaml.v3"
)

func Load(path string, vars map[string]string) (*InstallSpec, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseSpec(data, vars)
}

func LoadInline(input string, vars map[string]string) (*InstallSpec, error) {
	return parseSpec([]byte(input), vars)
}

func parseSpec(data []byte, vars map[string]string) (*InstallSpec, error) {
	var spec InstallSpec
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return nil, err
	}
	if err := applyTemplates(&spec, vars); err != nil {
		return nil, err
	}
	if err := spec.Validate(); err != nil {
		return nil, err
	}
	return &spec, nil
}

func applyTemplates(spec *InstallSpec, vars map[string]string) error {
	for idx := range spec.Steps {
		rendered, err := renderParams(spec.Steps[idx].Params, vars)
		if err != nil {
			return err
		}
		spec.Steps[idx].Params = rendered
	}
	return nil
}

func renderParams(input map[string]any, vars map[string]string) (map[string]any, error) {
	out := make(map[string]any, len(input))
	for key, value := range input {
		rendered, err := renderValue(value, vars)
		if err != nil {
			return nil, fmt.Errorf("step param %q: %w", key, err)
		}
		out[key] = rendered
	}
	return out, nil
}

func renderValue(value any, vars map[string]string) (any, error) {
	switch v := value.(type) {
	case string:
		return renderString(v, vars)
	case map[string]any:
		return renderParams(v, vars)
	case []any:
		result := make([]any, len(v))
		for i, element := range v {
			rendered, err := renderValue(element, vars)
			if err != nil {
				return nil, err
			}
			result[i] = rendered
		}
		return result, nil
	default:
		return v, nil
	}
}

func renderString(input string, vars map[string]string) (string, error) {
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
