package installer

import (
	"context"
	"fmt"
	"os/user"

	"github.com/globulario/globular-installer/internal/platform"
)

type EnsureUserGroupStep struct {
	User   string
	Group  string
	Home   string
	Shell  string
	System bool
}

func NewEnsureUserGroup(user, group string) *EnsureUserGroupStep {
	if user == "" {
		user = "globular"
	}
	if group == "" {
		group = "globular"
	}
	return &EnsureUserGroupStep{
		User:   user,
		Group:  group,
		Home:   "/var/lib/globular",
		Shell:  "/usr/sbin/nologin",
		System: true,
	}
}

func (s *EnsureUserGroupStep) Name() string {
	return "ensure-user-group"
}

func (s *EnsureUserGroupStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("context is required")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("platform is required")
	}
	if _, err := user.Lookup(s.User); err != nil {
		if _, ok := err.(user.UnknownUserError); ok {
			return StatusNeedsApply, nil
		}
		return StatusUnknown, fmt.Errorf("lookup user %s: %w", s.User, err)
	}
	if _, err := user.LookupGroup(s.Group); err != nil {
		if _, ok := err.(user.UnknownGroupError); ok {
			return StatusNeedsApply, nil
		}
		return StatusUnknown, fmt.Errorf("lookup group %s: %w", s.Group, err)
	}
	return StatusOK, nil
}

func (s *EnsureUserGroupStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("context is required")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("platform is required")
	}

	user := platform.UserSpec{
		Name:   s.User,
		Group:  s.Group,
		Home:   s.Home,
		Shell:  s.Shell,
		System: true,
	}
	group := platform.GroupSpec{
		Name:   s.Group,
		System: true,
	}

	if err := ctx.Platform.EnsureUserGroup(context.Background(), user, group); err != nil {
		return fmt.Errorf("ensure user/group: %w", err)
	}

	return nil
}
