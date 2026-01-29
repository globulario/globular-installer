package installer

import (
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
)

// PortAllocator provides range-checked, conflict-aware port reservations.
type PortAllocator struct {
	start    int
	end      int
	reserved map[int]string
}

func NewPortAllocator(start, end int) (*PortAllocator, error) {
	if start <= 0 || end <= 0 || start >= end || end > 65535 {
		return nil, fmt.Errorf("invalid port range %d-%d", start, end)
	}
	return &PortAllocator{
		start:    start,
		end:      end,
		reserved: make(map[int]string),
	}, nil
}

// Reserve chooses a free port for service, preferring the provided candidates.
func (p *PortAllocator) Reserve(service string, candidates ...int) (int, error) {
	if p == nil {
		return 0, fmt.Errorf("port allocator not initialized")
	}
	try := make([]int, 0, len(candidates)+(p.end-p.start+1))
	for _, c := range candidates {
		if c >= p.start && c <= p.end {
			try = append(try, c)
		}
	}
	for port := p.start; port <= p.end; port++ {
		try = append(try, port)
	}
	seen := make(map[int]struct{})
	for _, port := range try {
		if _, dup := seen[port]; dup {
			continue
		}
		seen[port] = struct{}{}
		if port < p.start || port > p.end {
			continue
		}
		if owner, exists := p.reserved[port]; exists && owner != service {
			continue
		}
		if portInUse(port) {
			continue
		}
		p.reserved[port] = service
		return port, nil
	}
	return 0, fmt.Errorf("no free ports in range %d-%d", p.start, p.end)
}

func (p *PortAllocator) Reserved() map[int]string {
	out := make(map[int]string, len(p.reserved))
	for k, v := range p.reserved {
		out[k] = v
	}
	return out
}

func (p *PortAllocator) Range() (int, int) {
	return p.start, p.end
}

func (p *PortAllocator) SortedPorts() []int {
	ports := make([]int, 0, len(p.reserved))
	for port := range p.reserved {
		ports = append(ports, port)
	}
	sort.Ints(ports)
	return ports
}

func portInUse(port int) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	l, err := net.Listen("tcp", addr)
	if err != nil {
		if errors.Is(err, net.ErrClosed) {
			return true
		}
		if strings.Contains(strings.ToLower(err.Error()), "address already in use") {
			return true
		}
		// For other errors (e.g., permission), assume free so installer can progress;
		// the service start will still fail if the port is actually unusable.
		return false
	}
	_ = l.Close()
	return false
}
