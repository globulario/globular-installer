package linux

import (
	"context"

	platform "github.com/globulario/globular-installer/internal/platform"
)

type SystemdManager struct{}

func NewSystemdManager() *SystemdManager {
	return &SystemdManager{}
}

func (s *SystemdManager) DaemonReload(ctx context.Context) error {
	_ = ctx
	return nil
}

func (s *SystemdManager) Enable(ctx context.Context, name string) error {
	_ = ctx
	_ = name
	return nil
}

func (s *SystemdManager) Disable(ctx context.Context, name string) error {
	_ = ctx
	_ = name
	return nil
}

func (s *SystemdManager) Start(ctx context.Context, name string) error {
	_ = ctx
	_ = name
	return nil
}

func (s *SystemdManager) Stop(ctx context.Context, name string) error {
	_ = ctx
	_ = name
	return nil
}

func (s *SystemdManager) Restart(ctx context.Context, name string) error {
	_ = ctx
	_ = name
	return nil
}

func (s *SystemdManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	_ = ctx
	_ = name
	return platform.ServiceStatus{
		Name:   name,
		State:  platform.ServiceUnknown,
		Detail: "stub",
	}, nil
}

func (s *SystemdManager) IsActive(ctx context.Context, name string) (bool, error) {
	status, err := s.Status(ctx, name)
	if err != nil {
		return false, err
	}
	return status.State == platform.ServiceActive, nil
}
