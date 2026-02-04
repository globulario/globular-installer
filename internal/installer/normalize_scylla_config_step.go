package installer

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// NormalizeScyllaConfigStep ensures /etc/scylla/scylla.yaml has correct bindings
// to prevent "connection refused" errors during service startup.
type NormalizeScyllaConfigStep struct {
	// ScyllaConfigPath is the path to scylla.yaml (default: /etc/scylla/scylla.yaml)
	ScyllaConfigPath string
	// ListenAddress is the primary IP address Scylla should bind to
	ListenAddress string
	// RPCAddress is the RPC binding (default: 0.0.0.0 for single-node)
	RPCAddress string
	// BroadcastRPCAddress is the advertised RPC address
	BroadcastRPCAddress string
	// NativeTransportPort is the CQL port (default: 9042)
	NativeTransportPort string
	// ValidatePort ensures port 9042 is listening after restart
	ValidatePort bool
	// ValidationTimeoutSec is max seconds to wait for port (default: 90)
	ValidationTimeoutSec int
}

func (s *NormalizeScyllaConfigStep) Name() string {
	return "normalize-scylla-config"
}

func (s *NormalizeScyllaConfigStep) defaults() {
	if s.ScyllaConfigPath == "" {
		s.ScyllaConfigPath = "/etc/scylla/scylla.yaml"
	}
	if s.RPCAddress == "" {
		s.RPCAddress = "0.0.0.0"
	}
	if s.NativeTransportPort == "" {
		s.NativeTransportPort = "9042"
	}
	if s.ValidationTimeoutSec == 0 {
		s.ValidationTimeoutSec = 90
	}
	if s.BroadcastRPCAddress == "" && s.ListenAddress != "" {
		s.BroadcastRPCAddress = s.ListenAddress
	}
}

func (s *NormalizeScyllaConfigStep) Check(ctx *Context) (StepStatus, error) {
	s.defaults()

	// Check if scylla config exists
	if _, err := os.Stat(s.ScyllaConfigPath); err != nil {
		if os.IsNotExist(err) {
			// Scylla not installed, skip
			return StatusSkipped, nil
		}
		return StatusUnknown, fmt.Errorf("stat scylla config: %w", err)
	}

	// Read current config
	data, err := os.ReadFile(s.ScyllaConfigPath)
	if err != nil {
		return StatusUnknown, fmt.Errorf("read scylla config: %w", err)
	}

	needsNormalization := false

	// Check for issues that need fixing
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		// Check for trailing whitespace in seeds
		if strings.HasPrefix(trimmed, "- seeds:") {
			if strings.HasSuffix(line, " ") || strings.HasSuffix(line, "\t") {
				needsNormalization = true
				break
			}
		}

		// Check if native_transport_port_ssl is present when TLS is disabled
		// (this causes port binding conflicts)
		if strings.HasPrefix(trimmed, "native_transport_port_ssl:") {
			// Look for client_encryption_options.enabled: false
			configStr := string(data)
			if strings.Contains(configStr, "client_encryption_options") {
				if strings.Contains(configStr, "enabled: false") {
					needsNormalization = true
					break
				}
			}
		}
	}

	// Check if listen_address needs to be set
	if s.ListenAddress != "" {
		if !strings.Contains(string(data), "listen_address: "+s.ListenAddress) {
			needsNormalization = true
		}
	}

	// Check if rpc_address needs to be set
	if !strings.Contains(string(data), "rpc_address: "+s.RPCAddress) {
		needsNormalization = true
	}

	// Check if broadcast_rpc_address needs to be set
	if s.BroadcastRPCAddress != "" {
		if !strings.Contains(string(data), "broadcast_rpc_address: "+s.BroadcastRPCAddress) {
			needsNormalization = true
		}
	}

	if needsNormalization {
		return StatusNeedsApply, nil
	}

	return StatusOK, nil
}

func (s *NormalizeScyllaConfigStep) Apply(ctx *Context) error {
	s.defaults()

	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	// Read current config
	data, err := os.ReadFile(s.ScyllaConfigPath)
	if err != nil {
		return fmt.Errorf("read scylla config: %w", err)
	}

	// Normalize the config
	normalized, err := s.normalizeConfig(string(data))
	if err != nil {
		return fmt.Errorf("normalize config: %w", err)
	}

	// Write normalized config atomically
	tmpPath := s.ScyllaConfigPath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(normalized), 0644); err != nil {
		return fmt.Errorf("write temp config: %w", err)
	}
	if err := os.Rename(tmpPath, s.ScyllaConfigPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename config: %w", err)
	}

	// Restart Scylla to apply changes
	if err := s.restartScylla(ctx); err != nil {
		return fmt.Errorf("restart scylla: %w", err)
	}

	// Validate port is listening
	if s.ValidatePort {
		if err := s.validatePort(); err != nil {
			return fmt.Errorf("validate port: %w", err)
		}
	}

	return nil
}

func (s *NormalizeScyllaConfigStep) normalizeConfig(content string) (string, error) {
	var buf bytes.Buffer
	scanner := bufio.NewScanner(strings.NewReader(content))

	// Track which settings we've set
	setListenAddress := false
	setRPCAddress := false
	setBroadcastRPCAddress := false
	setNativeTransportPort := false
	inClientEncryption := false
	clientEncryptionEnabled := false

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)

		// Detect client_encryption_options section
		if strings.HasPrefix(trimmed, "client_encryption_options:") {
			inClientEncryption = true
			buf.WriteString(line + "\n")
			continue
		}

		// Detect enabled: false in client_encryption_options
		if inClientEncryption && strings.HasPrefix(trimmed, "enabled:") {
			if strings.Contains(trimmed, "false") {
				clientEncryptionEnabled = false
			} else {
				clientEncryptionEnabled = true
			}
			buf.WriteString(line + "\n")
			continue
		}

		// Exit client_encryption_options section
		if inClientEncryption && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed != "" {
			inClientEncryption = false
		}

		// Skip native_transport_port_ssl if TLS is disabled
		if strings.HasPrefix(trimmed, "native_transport_port_ssl:") && !clientEncryptionEnabled {
			buf.WriteString("# " + line + " # Commented out: TLS disabled\n")
			continue
		}

		// Trim trailing whitespace from seeds line
		if strings.HasPrefix(trimmed, "- seeds:") {
			// Extract the seeds value and trim it
			re := regexp.MustCompile(`(- seeds:\s*)"([^"]+)"`)
			if matches := re.FindStringSubmatch(line); len(matches) >= 3 {
				indent := strings.Repeat(" ", len(line)-len(strings.TrimLeft(line, " \t")))
				buf.WriteString(fmt.Sprintf("%s- seeds: \"%s\"\n", indent, strings.TrimSpace(matches[2])))
				continue
			}
		}

		// Replace listen_address
		if strings.HasPrefix(trimmed, "listen_address:") && s.ListenAddress != "" {
			indent := strings.Repeat(" ", len(line)-len(strings.TrimLeft(line, " \t")))
			buf.WriteString(fmt.Sprintf("%slisten_address: %s\n", indent, s.ListenAddress))
			setListenAddress = true
			continue
		}

		// Replace rpc_address
		if strings.HasPrefix(trimmed, "rpc_address:") {
			indent := strings.Repeat(" ", len(line)-len(strings.TrimLeft(line, " \t")))
			buf.WriteString(fmt.Sprintf("%srpc_address: %s\n", indent, s.RPCAddress))
			setRPCAddress = true
			continue
		}

		// Replace broadcast_rpc_address
		if strings.HasPrefix(trimmed, "broadcast_rpc_address:") && s.BroadcastRPCAddress != "" {
			indent := strings.Repeat(" ", len(line)-len(strings.TrimLeft(line, " \t")))
			buf.WriteString(fmt.Sprintf("%sbroadcast_rpc_address: %s\n", indent, s.BroadcastRPCAddress))
			setBroadcastRPCAddress = true
			continue
		}

		// Replace native_transport_port
		if strings.HasPrefix(trimmed, "native_transport_port:") {
			indent := strings.Repeat(" ", len(line)-len(strings.TrimLeft(line, " \t")))
			buf.WriteString(fmt.Sprintf("%snative_transport_port: %s\n", indent, s.NativeTransportPort))
			setNativeTransportPort = true
			continue
		}

		// Write line as-is
		buf.WriteString(line + "\n")
	}

	if err := scanner.Err(); err != nil {
		return "", err
	}

	// Append missing settings if not found
	result := buf.String()
	if !setListenAddress && s.ListenAddress != "" {
		result += fmt.Sprintf("\nlisten_address: %s\n", s.ListenAddress)
	}
	if !setRPCAddress {
		result += fmt.Sprintf("rpc_address: %s\n", s.RPCAddress)
	}
	if !setBroadcastRPCAddress && s.BroadcastRPCAddress != "" {
		result += fmt.Sprintf("broadcast_rpc_address: %s\n", s.BroadcastRPCAddress)
	}
	if !setNativeTransportPort {
		result += fmt.Sprintf("native_transport_port: %s\n", s.NativeTransportPort)
	}

	return result, nil
}

func (s *NormalizeScyllaConfigStep) restartScylla(ctx *Context) error {
	if ctx.Platform.ServiceManager() == nil {
		return fmt.Errorf("no service manager available")
	}

	mgr := ctx.Platform.ServiceManager()

	// Restart scylla-server service
	if err := mgr.Restart(context.Background(), "scylla-server"); err != nil {
		return fmt.Errorf("systemctl restart scylla-server: %w", err)
	}

	return nil
}

func (s *NormalizeScyllaConfigStep) validatePort() error {
	deadline := time.Now().Add(time.Duration(s.ValidationTimeoutSec) * time.Second)

	for time.Now().Before(deadline) {
		// Check if port 9042 is listening using ss command
		cmd := exec.Command("ss", "-lnt")
		output, err := cmd.Output()
		if err == nil {
			if bytes.Contains(output, []byte(":"+s.NativeTransportPort)) {
				return nil
			}
		}

		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("scylla port %s not listening after %d seconds", s.NativeTransportPort, s.ValidationTimeoutSec)
}
