package hostsblock

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureManagedBlock_NewBlock(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	// Create initial hosts file
	initial := "127.0.0.1 localhost\n::1 localhost\n"
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Add managed block
	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local", "controller"}},
		{IP: "10.0.1.101", Names: []string{"gateway.cluster.local", "gateway"}},
	}

	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("EnsureManagedBlock failed: %v", err)
	}

	// Read result
	content, err := os.ReadFile(hostsPath)
	if err != nil {
		t.Fatalf("read file: %v", err)
	}

	result := string(content)

	// Verify original content preserved
	if !strings.Contains(result, "127.0.0.1 localhost") {
		t.Error("original localhost entry missing")
	}

	// Verify managed block exists
	if !strings.Contains(result, "# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)") {
		t.Error("BEGIN marker missing")
	}
	if !strings.Contains(result, "# END GLOBULAR MANAGED HOSTS (cluster.local)") {
		t.Error("END marker missing")
	}
	if !strings.Contains(result, "10.0.1.100 controller.cluster.local controller") {
		t.Error("controller entry missing")
	}
	if !strings.Contains(result, "10.0.1.101 gateway.cluster.local gateway") {
		t.Error("gateway entry missing")
	}

	// Verify ends with newline
	if !strings.HasSuffix(result, "\n") {
		t.Error("file doesn't end with newline")
	}
}

func TestEnsureManagedBlock_ReplaceExisting(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	// Create file with existing managed block
	initial := `127.0.0.1 localhost
# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)
10.0.1.50 old.cluster.local
# END GLOBULAR MANAGED HOSTS (cluster.local)
192.168.1.1 router
`
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Replace with new entries
	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local"}},
		{IP: "10.0.1.101", Names: []string{"node-01.cluster.local"}},
	}

	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("EnsureManagedBlock failed: %v", err)
	}

	content, err := os.ReadFile(hostsPath)
	if err != nil {
		t.Fatalf("read file: %v", err)
	}

	result := string(content)

	// Verify old entry is gone
	if strings.Contains(result, "10.0.1.50 old.cluster.local") {
		t.Error("old entry still present")
	}

	// Verify new entries exist
	if !strings.Contains(result, "10.0.1.100 controller.cluster.local") {
		t.Error("new controller entry missing")
	}
	if !strings.Contains(result, "10.0.1.101 node-01.cluster.local") {
		t.Error("new node entry missing")
	}

	// Verify other content preserved
	if !strings.Contains(result, "127.0.0.1 localhost") {
		t.Error("localhost entry removed")
	}
	if !strings.Contains(result, "192.168.1.1 router") {
		t.Error("router entry removed")
	}
}

func TestEnsureManagedBlock_Idempotent(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	initial := "127.0.0.1 localhost\n"
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local"}},
	}

	// First write
	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("first write failed: %v", err)
	}

	content1, _ := os.ReadFile(hostsPath)

	// Second write (should be identical)
	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("second write failed: %v", err)
	}

	content2, _ := os.ReadFile(hostsPath)

	// Third write (should still be identical)
	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("third write failed: %v", err)
	}

	content3, _ := os.ReadFile(hostsPath)

	if string(content1) != string(content2) {
		t.Error("second write changed content")
	}
	if string(content2) != string(content3) {
		t.Error("third write changed content")
	}
}

func TestEnsureManagedBlock_NoTrailingNewline(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	// File without trailing newline
	initial := "127.0.0.1 localhost"
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local"}},
	}

	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("EnsureManagedBlock failed: %v", err)
	}

	content, _ := os.ReadFile(hostsPath)
	result := string(content)

	// Should handle gracefully and add newline
	if !strings.HasSuffix(result, "\n") {
		t.Error("result doesn't end with newline")
	}

	// Original content should be preserved
	if !strings.Contains(result, "127.0.0.1 localhost") {
		t.Error("localhost entry missing")
	}
}

func TestEnsureManagedBlock_DuplicateNames(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	if err := os.WriteFile(hostsPath, []byte("127.0.0.1 localhost\n"), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Entries with duplicate name
	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local", "controller"}},
		{IP: "10.0.1.101", Names: []string{"controller"}}, // Duplicate!
	}

	err := EnsureManagedBlock(hostsPath, "cluster.local", entries)
	if err == nil {
		t.Fatal("expected error for duplicate names, got nil")
	}

	if !strings.Contains(err.Error(), "duplicate") {
		t.Errorf("expected 'duplicate' in error, got: %v", err)
	}
}

func TestRemoveManagedBlock(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	// Create file with managed block
	initial := `127.0.0.1 localhost
# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)
10.0.1.100 controller.cluster.local
10.0.1.101 gateway.cluster.local
# END GLOBULAR MANAGED HOSTS (cluster.local)
192.168.1.1 router
`
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Remove managed block
	if err := RemoveManagedBlock(hostsPath, "cluster.local"); err != nil {
		t.Fatalf("RemoveManagedBlock failed: %v", err)
	}

	content, _ := os.ReadFile(hostsPath)
	result := string(content)

	// Verify block is gone
	if strings.Contains(result, "BEGIN GLOBULAR MANAGED HOSTS") {
		t.Error("managed block still present")
	}
	if strings.Contains(result, "controller.cluster.local") {
		t.Error("controller entry still present")
	}

	// Verify other content preserved
	if !strings.Contains(result, "127.0.0.1 localhost") {
		t.Error("localhost entry removed")
	}
	if !strings.Contains(result, "192.168.1.1 router") {
		t.Error("router entry removed")
	}
}

func TestRemoveManagedBlock_NotExists(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	initial := "127.0.0.1 localhost\n"
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Remove non-existent block (should be no-op)
	if err := RemoveManagedBlock(hostsPath, "cluster.local"); err != nil {
		t.Fatalf("RemoveManagedBlock failed: %v", err)
	}

	content, _ := os.ReadFile(hostsPath)

	if string(content) != initial {
		t.Error("file was modified when block didn't exist")
	}
}

func TestRemoveManagedBlock_Idempotent(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	initial := `127.0.0.1 localhost
# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)
10.0.1.100 controller.cluster.local
# END GLOBULAR MANAGED HOSTS (cluster.local)
`
	if err := os.WriteFile(hostsPath, []byte(initial), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// First removal
	if err := RemoveManagedBlock(hostsPath, "cluster.local"); err != nil {
		t.Fatalf("first removal failed: %v", err)
	}

	content1, _ := os.ReadFile(hostsPath)

	// Second removal (should be no-op)
	if err := RemoveManagedBlock(hostsPath, "cluster.local"); err != nil {
		t.Fatalf("second removal failed: %v", err)
	}

	content2, _ := os.ReadFile(hostsPath)

	if string(content1) != string(content2) {
		t.Error("second removal changed content")
	}
}

func TestPreservePermissions(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	// Create file with specific permissions
	if err := os.WriteFile(hostsPath, []byte("127.0.0.1 localhost\n"), 0600); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	entries := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster.local"}},
	}

	if err := EnsureManagedBlock(hostsPath, "cluster.local", entries); err != nil {
		t.Fatalf("EnsureManagedBlock failed: %v", err)
	}

	// Check permissions preserved
	info, err := os.Stat(hostsPath)
	if err != nil {
		t.Fatalf("stat file: %v", err)
	}

	if info.Mode().Perm() != 0600 {
		t.Errorf("permissions changed: expected 0600, got %o", info.Mode().Perm())
	}
}

func TestMultipleBlocks(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	if err := os.WriteFile(hostsPath, []byte("127.0.0.1 localhost\n"), 0644); err != nil {
		t.Fatalf("write initial file: %v", err)
	}

	// Add first block
	entries1 := []HostEntry{
		{IP: "10.0.1.100", Names: []string{"controller.cluster1.local"}},
	}
	if err := EnsureManagedBlock(hostsPath, "cluster1.local", entries1); err != nil {
		t.Fatalf("first block failed: %v", err)
	}

	// Add second block (different cluster)
	entries2 := []HostEntry{
		{IP: "10.0.2.100", Names: []string{"controller.cluster2.local"}},
	}
	if err := EnsureManagedBlock(hostsPath, "cluster2.local", entries2); err != nil {
		t.Fatalf("second block failed: %v", err)
	}

	content, _ := os.ReadFile(hostsPath)
	result := string(content)

	// Both blocks should exist
	if !strings.Contains(result, "cluster1.local") {
		t.Error("cluster1 block missing")
	}
	if !strings.Contains(result, "cluster2.local") {
		t.Error("cluster2 block missing")
	}
	if !strings.Contains(result, "10.0.1.100") {
		t.Error("cluster1 IP missing")
	}
	if !strings.Contains(result, "10.0.2.100") {
		t.Error("cluster2 IP missing")
	}

	// Remove first block
	if err := RemoveManagedBlock(hostsPath, "cluster1.local"); err != nil {
		t.Fatalf("remove cluster1 failed: %v", err)
	}

	content, _ = os.ReadFile(hostsPath)
	result = string(content)

	// Cluster1 should be gone, cluster2 should remain
	if strings.Contains(result, "10.0.1.100") {
		t.Error("cluster1 IP still present")
	}
	if !strings.Contains(result, "10.0.2.100") {
		t.Error("cluster2 IP removed")
	}
}

func TestParseHostsFile(t *testing.T) {
	tmpDir := t.TempDir()
	hostsPath := filepath.Join(tmpDir, "hosts")

	content := `# Comment line
127.0.0.1 localhost
::1 localhost ip6-localhost
10.0.1.100 controller.cluster.local controller

# Another comment
192.168.1.1 router
`
	if err := os.WriteFile(hostsPath, []byte(content), 0644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	entries, err := ParseHostsFile(hostsPath)
	if err != nil {
		t.Fatalf("ParseHostsFile failed: %v", err)
	}

	if len(entries) != 4 {
		t.Fatalf("expected 4 entries, got %d", len(entries))
	}

	// Check first entry
	if entries[0].IP != "127.0.0.1" || entries[0].Names[0] != "localhost" {
		t.Errorf("entry 0 incorrect: %+v", entries[0])
	}

	// Check entry with multiple names
	if entries[1].IP != "::1" || len(entries[1].Names) != 2 {
		t.Errorf("entry 1 incorrect: %+v", entries[1])
	}

	// Check entry with FQDN and short name
	if entries[2].IP != "10.0.1.100" || entries[2].Names[0] != "controller.cluster.local" {
		t.Errorf("entry 2 incorrect: %+v", entries[2])
	}
}
