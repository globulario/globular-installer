package installer

import (
	"fmt"
	"strings"
)

type Plan struct {
	Name  string
	Steps []Step
}

func NewPlan(name string, steps ...Step) *Plan {
	if name == "" {
		name = "unnamed-plan"
	}
	filtered := make([]Step, 0, len(steps))
	for _, s := range steps {
		if s != nil {
			filtered = append(filtered, s)
		}
	}
	copied := append([]Step(nil), filtered...)
	return &Plan{Name: name, Steps: copied}
}

func (p *Plan) Validate() error {
	if p == nil {
		return fmt.Errorf("plan is nil")
	}
	if len(p.Steps) == 0 {
		return fmt.Errorf("plan %q has no steps", p.Name)
	}
	for idx, step := range p.Steps {
		if step == nil {
			return fmt.Errorf("step %d in plan %q is nil", idx+1, p.Name)
		}
		if strings.TrimSpace(step.Name()) == "" {
			return fmt.Errorf("step %d in plan %q has empty name", idx+1, p.Name)
		}
	}
	return nil
}
