package installer

type Runner struct{}

func NewRunner() *Runner {
	return &Runner{}
}

type RunMode int

type RunReport struct{}

func (r *Runner) Run(ctx *Context, p *Plan, mode RunMode) (*RunReport, error) {
	_ = r
	_ = ctx
	_ = p
	_ = mode
	return &RunReport{}, nil
}
