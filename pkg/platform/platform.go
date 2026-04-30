// Package platform provides OS-agnostic contracts that the installer uses instead of
// performing system-specific work directly.
//
// It hides user/group setup, filesystem helpers, and service management so the
// core logic stays portable.
package platform

import (
	"context"
	"fmt"
	"io/fs"
	"strings"
)

type UserSpec struct {
	Name   string
	Group  string
	Home   string
	Shell  string
	System bool
}

type GroupSpec struct {
	Name   string
	System bool
}

type DirSpec struct {
	Path  string
	Owner string
	Group string
	Mode  fs.FileMode
}

type FileSpec struct {
	Path         string
	Data         []byte
	Owner        string
	Group        string
	Mode         fs.FileMode
	Atomic       bool
	// SkipIfExists instructs the installer to leave the file untouched when it
	// already exists on disk.  Use this for seed-only configs (e.g. etcd.yaml)
	// whose authoritative content is written by the controller or join scripts
	// and must survive package reinstalls.
	SkipIfExists bool
}

type InstallFilesResult struct {
	Changed []string
}

type FileInstallerWithResult interface {
	InstallFilesWithResult(ctx context.Context, files []FileSpec) (InstallFilesResult, error)
}

type Platform interface {
	Name() string
	EnsureUserGroup(ctx context.Context, user UserSpec, group GroupSpec) error
	EnsureDirs(ctx context.Context, dirs []DirSpec) error
	InstallFiles(ctx context.Context, files []FileSpec) error
	ServiceManager() ServiceManager
}

func (u UserSpec) Validate() error {
	if strings.TrimSpace(u.Name) == "" {
		return fmt.Errorf("user name is required")
	}
	return nil
}

func (g GroupSpec) Validate() error {
	if strings.TrimSpace(g.Name) == "" {
		return fmt.Errorf("group name is required")
	}
	return nil
}

func (d DirSpec) Validate() error {
	if strings.TrimSpace(d.Path) == "" {
		return fmt.Errorf("dir path is required")
	}
	return nil
}

func (f FileSpec) Validate() error {
	if strings.TrimSpace(f.Path) == "" {
		return fmt.Errorf("file path is required")
	}
	return nil
}
