package installer

import (
	"fmt"
	"net"
	"testing"
)

func TestPortAllocatorReservesUniqueAndSkipsInUse(t *testing.T) {
	base := 45000
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", base))
	if err != nil {
		t.Skipf("could not bind test port %d: %v", base, err)
	}
	defer ln.Close()

	pa, err := NewPortAllocator(base, base+2)
	if err != nil {
		t.Fatalf("allocator init: %v", err)
	}

	p1, err := pa.Reserve("svc1", base, base+1)
	if err != nil {
		t.Fatalf("reserve1: %v", err)
	}
	if p1 == base {
		t.Fatalf("allocator picked in-use port %d", base)
	}

	p2, err := pa.Reserve("svc2", base, base+1)
	if err != nil {
		t.Fatalf("reserve2: %v", err)
	}
	if p2 == p1 {
		t.Fatalf("expected distinct ports, got %d twice", p1)
	}

	p3, err := pa.Reserve("svc3")
	if err != nil {
		t.Fatalf("reserve3: %v", err)
	}
	if p3 == p1 || p3 == p2 {
		t.Fatalf("expected unique third port, got duplicate %d", p3)
	}

	if _, err := pa.Reserve("svc4"); err == nil {
		t.Fatalf("expected exhaustion error, got none")
	}
}

func TestPortInUseDetectsWildcardListeners(t *testing.T) {
	ln, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		t.Skipf("could not bind wildcard: %v", err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	if !portInUse(port) {
		t.Fatalf("expected portInUse to detect wildcard listener on port %d", port)
	}
}
