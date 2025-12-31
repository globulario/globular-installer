package installer

type Context struct {
	Logger Logger
	DryRun bool
}

func NewContext(opts Options) (*Context, error) {
	_ = opts
	return &Context{}, nil
}
