package installer

type NoopStep struct {
	name string
}

func NewNoop(name string) *NoopStep {
	if name == "" {
		name = "noop"
	}
	return &NoopStep{name: name}
}

func (s *NoopStep) Name() string {
	return s.name
}

func (s *NoopStep) Check(ctx *Context) (StepStatus, error) {
	_ = ctx
	return StatusOK, nil
}

func (s *NoopStep) Apply(ctx *Context) error {
	_ = ctx
	return nil
}
