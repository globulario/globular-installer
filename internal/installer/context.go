package installer

type Context struct{}

func NewContext(opts Options) (*Context, error) {
	_ = opts
	return &Context{}, nil
}
