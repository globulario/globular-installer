package linux

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/globulario/globular-installer/pkg/platform"
)

func runCmd(ctx context.Context, name string, args ...string) (string, string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	return strings.TrimSpace(outBuf.String()), strings.TrimSpace(errBuf.String()), err
}

func cmdErr(op string, name string, args []string, stderr string, err error) error {
	base := strings.Join(args, " ")
	if stderr == "" {
		return fmt.Errorf("%s %s %s: %w", op, name, base, err)
	}
	return fmt.Errorf("%s %s %s: %s: %w", op, name, base, stderr, err)
}

func groupExists(ctx context.Context, group string) (bool, error) {
	if strings.TrimSpace(group) == "" {
		return false, fmt.Errorf("group name is required")
	}
	_, _, err := runCmd(ctx, "getent", "group", group)
	if err == nil {
		return true, nil
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	return false, nil
}

func userExists(ctx context.Context, user string) (bool, error) {
	if strings.TrimSpace(user) == "" {
		return false, fmt.Errorf("user name is required")
	}
	_, _, err := runCmd(ctx, "getent", "passwd", user)
	if err == nil {
		return true, nil
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	return false, nil
}

func ensureGroup(ctx context.Context, g platform.GroupSpec) error {
	if strings.TrimSpace(g.Name) == "" {
		return fmt.Errorf("group name is required")
	}
	exists, err := groupExists(ctx, g.Name)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	args := make([]string, 0)
	if g.System {
		args = append(args, "--system")
	}
	args = append(args, g.Name)
	if _, stderr, err := runCmd(ctx, "groupadd", args...); err != nil {
		return cmdErr("groupadd", "groupadd", args, stderr, err)
	}
	return nil
}

func ensureUser(ctx context.Context, u platform.UserSpec) error {
	if strings.TrimSpace(u.Name) == "" {
		return fmt.Errorf("user name is required")
	}
	exists, err := userExists(ctx, u.Name)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	args := make([]string, 0)
	if u.System {
		args = append(args, "--system")
	}
	if u.Group != "" {
		args = append(args, "-g", u.Group)
	}
	if u.Home != "" {
		args = append(args, "-d", u.Home, "-m")
	}
	if u.Shell != "" {
		args = append(args, "-s", u.Shell)
	}
	args = append(args, u.Name)
	if _, stderr, err := runCmd(ctx, "useradd", args...); err != nil {
		return cmdErr("useradd", "useradd", args, stderr, err)
	}
	return nil
}

func ensureUserPrimaryGroup(ctx context.Context, user, group string) error {
	if strings.TrimSpace(user) == "" || strings.TrimSpace(group) == "" {
		return nil
	}
	out, stderr, err := runCmd(ctx, "id", "-gn", user)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return cmdErr("id -gn", "id", []string{"-gn", user}, stderr, err)
	}
	current := strings.TrimSpace(out)
	if current == group {
		return nil
	}
	args := []string{"-g", group, user}
	if _, stderr, err := runCmd(ctx, "usermod", args...); err != nil {
		return cmdErr("usermod", "usermod", args, stderr, err)
	}
	return nil
}

// EnsureUserGroup ensures the group and user exist and the user's primary group matches.
func EnsureUserGroup(ctx context.Context, u platform.UserSpec, g platform.GroupSpec) error {
	if err := ensureGroup(ctx, g); err != nil {
		return err
	}
	targetGroup := u.Group
	if targetGroup == "" {
		targetGroup = g.Name
	}
	userSpec := u
	if userSpec.Group == "" {
		userSpec.Group = targetGroup
	}
	if err := ensureUser(ctx, userSpec); err != nil {
		return err
	}
	if err := ensureUserPrimaryGroup(ctx, u.Name, targetGroup); err != nil {
		return err
	}
	return nil
}
