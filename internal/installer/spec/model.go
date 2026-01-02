package spec

import "fmt"

type InstallSpec struct {
	Version int        `yaml:"version"`
	Steps   []StepSpec `yaml:"steps"`
}

type StepSpec struct {
	ID     string         `yaml:"id"`
	Type   string         `yaml:"type"`
	Params map[string]any `yaml:",inline"`
}

func (s *InstallSpec) Validate() error {
	if s.Version != 1 {
		return fmt.Errorf("unsupported spec version %d", s.Version)
	}
	seen := make(map[string]struct{})
	for i, step := range s.Steps {
		if step.ID == "" {
			return fmt.Errorf("step %d is missing id", i+1)
		}
		if _, exists := seen[step.ID]; exists {
			return fmt.Errorf("step id %q is duplicated", step.ID)
		}
		seen[step.ID] = struct{}{}
		if step.Type == "" {
			return fmt.Errorf("step %q has empty type", step.ID)
		}
	}
	return nil
}
