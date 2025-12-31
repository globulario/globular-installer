// Package platform provides service management contracts so installers can control
// daemons without coupling to a concrete system.
package platform

import (
	"context"
	"fmt"
	"strings"
)

type ServiceState int

const (
	ServiceUnknown ServiceState = iota
	ServiceInactive
	ServiceActive
	ServiceFailed
)

func (s ServiceState) String() string {
	switch s {
	case ServiceInactive:
		return "inactive"
	case ServiceActive:
		return "active"
	case ServiceFailed:
		return "failed"
	default:
		return "unknown"
	}
}

type ServiceStatus struct {
	Name   string
	State  ServiceState
	Detail string
}

type ServiceManager interface {
	DaemonReload(ctx context.Context) error
	Enable(ctx context.Context, name string) error
	Disable(ctx context.Context, name string) error
	Start(ctx context.Context, name string) error
	Stop(ctx context.Context, name string) error
	Restart(ctx context.Context, name string) error
	Status(ctx context.Context, name string) (ServiceStatus, error)
	IsActive(ctx context.Context, name string) (bool, error)
}

func ValidateServiceName(name string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("service name is required")
	}
	if strings.ContainsAny(name, " \t\n\r") {
		return fmt.Errorf("service name %q contains whitespace", name)
	}
	return nil
}
