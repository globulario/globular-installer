package installer

type Plan struct{}

func NewPlan(name string, steps ...Step) *Plan {
	_ = name
	_ = steps
	return &Plan{}
}
