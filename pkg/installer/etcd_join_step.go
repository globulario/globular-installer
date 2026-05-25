package installer

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// EtcdJoinStep performs the Day-1 etcd cluster join protocol:
//
//  1. Remove ghost/stale member for this node's peer URL (previous failed join).
//  2. Acquire a 300-second join-lock in etcd (guards against controller eviction race).
//  3. Read current named members and build the initial-cluster string.
//  4. etcdctl member add.
//  5. Write etcd.yaml with initial-cluster-state: existing.
//  6. Write etcd_endpoints file.
//  7. Start globular-etcd.service via systemctl.
//  8. Poll local etcd health (60 s timeout).
//  9. Verify this node appears as a named member from the bootstrap cluster.
//
// Returns StatusSkipped when BootstrapEtcd is empty (Day-0 single-node path).
type EtcdJoinStep struct {
	BootstrapEtcd string // e.g. "https://10.0.0.63:2379"; empty → skip (Day-0)
	applied       bool
}

func (s *EtcdJoinStep) Name() string { return "etcd-join" }

func (s *EtcdJoinStep) Check(ctx *Context) (StepStatus, error) {
	if s.BootstrapEtcd == "" {
		return StatusSkipped, nil
	}
	if s.applied {
		return StatusOK, nil
	}
	// Idempotent: if etcd.yaml already declares initial-cluster-state: existing, skip.
	yamlPath := filepath.Join(ctx.StateDir, "config", "etcd.yaml")
	data, err := os.ReadFile(yamlPath)
	if err == nil && bytes.Contains(data, []byte(`initial-cluster-state: "existing"`)) {
		return StatusOK, nil
	}
	return StatusNeedsApply, nil
}

func (s *EtcdJoinStep) Apply(ctx *Context) error {
	if s.BootstrapEtcd == "" {
		return nil
	}

	nodeIP := "127.0.0.1"
	if ip, ok := ctx.TemplateVars["NodeIP"]; ok && ip != "" {
		nodeIP = ip
	}

	hostname, err := os.Hostname()
	if err != nil {
		return fmt.Errorf("etcd-join: get hostname: %w", err)
	}
	etcdName := etcdSanitizeName(hostname)
	if etcdName == "" {
		etcdName = "node"
	}

	etcdctlPath := filepath.Join(ctx.Prefix, "bin", "etcdctl")
	caCert := filepath.Join(ctx.StateDir, "pki", "ca.crt")
	cert := filepath.Join(ctx.StateDir, "pki", "issued", "services", "service.crt")
	key := filepath.Join(ctx.StateDir, "pki", "issued", "services", "service.key")
	cfgDir := filepath.Join(ctx.StateDir, "config")
	yamlPath := filepath.Join(cfgDir, "etcd.yaml")
	endpointsPath := filepath.Join(cfgDir, "etcd_endpoints")

	logf := func(format string, a ...any) {
		if ctx.Logger != nil {
			ctx.Logger.Infof(format, a...)
		}
	}

	etcdctlRun := func(args ...string) (string, error) {
		all := append([]string{
			"--endpoints=" + s.BootstrapEtcd,
			"--cacert=" + caCert,
			"--cert=" + cert,
			"--key=" + key,
		}, args...)
		cmd := exec.Command(etcdctlPath, all...)
		cmd.Env = append(os.Environ(), "ETCDCTL_API=3")
		out, err := cmd.CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}

	if ctx.DryRun {
		logf("[dry-run] etcd-join: would join cluster at %s as %q", s.BootstrapEtcd, etcdName)
		s.applied = true
		return nil
	}

	// [5.1] Remove ghost/stale member for this node's IP.
	logf("[5.1] Checking for stale etcd member at %s:2380...", nodeIP)
	if memberList, listErr := etcdctlRun("member", "list"); listErr == nil {
		for _, line := range strings.Split(memberList, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || !strings.Contains(line, nodeIP) {
				continue
			}
			fields := strings.SplitN(line, ",", 2)
			if len(fields) == 0 {
				continue
			}
			ghostID := strings.TrimSpace(fields[0])
			if ghostID == "" {
				continue
			}
			logf("[5.1] Removing stale member %s for %s...", ghostID, nodeIP)
			if _, removeErr := etcdctlRun("member", "remove", ghostID); removeErr != nil {
				logf("[5.1] member remove %s: %v (may already be gone)", ghostID, removeErr)
			} else {
				logf("[5.1] Stale member %s removed", ghostID)
			}
		}
	}

	// [5.2.5] Acquire join-lock (300s lease) to prevent controller eviction during join.
	logf("[5.2.5] Acquiring etcd-join lock for %s...", etcdName)
	if leaseOut, leaseErr := etcdctlRun("lease", "grant", "300"); leaseErr == nil {
		if leaseID := etcdExtractLeaseID(leaseOut); leaseID != "" {
			lockKey := "/globular/etcd_joins/" + etcdName
			lockVal := fmt.Sprintf(`{"peer_url":"https://%s:2380","started_unix":%d}`, nodeIP, time.Now().Unix())
			if _, putErr := etcdctlRun("put", lockKey, lockVal, "--lease="+leaseID); putErr != nil {
				logf("[5.2.5] join-lock put failed: %v (continuing)", putErr)
			} else {
				logf("[5.2.5] join-lock acquired (lease=%s, ttl=300s)", leaseID)
			}
		} else {
			logf("[5.2.5] could not parse lease ID from: %s (continuing)", leaseOut)
		}
	} else {
		logf("[5.2.5] lease grant failed: %v (proceeding without lock)", leaseErr)
	}

	// [5.2] Read current named members and build initial-cluster string.
	logf("[5.2] Reading current etcd members...")
	initialCluster := ""
	if memberList, listErr := etcdctlRun("member", "list"); listErr == nil {
		bootstrapHost := etcdExtractHost(s.BootstrapEtcd)
		loopbackRE := regexp.MustCompile(`https?://(127\.0\.0\.1|localhost|\[::1\])`)
		for _, line := range strings.Split(memberList, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			parts := strings.Split(line, ",")
			if len(parts) < 4 {
				continue
			}
			name := strings.TrimSpace(parts[2])
			peerURLs := strings.TrimSpace(parts[3])
			if name == "" {
				continue // skip ghost (unnamed) members — they corrupt initial-cluster
			}
			// Normalise loopback peer URLs to the bootstrap host's real IP.
			if bootstrapHost != "" {
				peerURLs = loopbackRE.ReplaceAllString(peerURLs, "https://"+bootstrapHost)
			}
			if initialCluster != "" {
				initialCluster += ","
			}
			initialCluster += name + "=" + peerURLs
		}
	}

	// [5.3] Add this node as a new etcd member.
	peerURL := fmt.Sprintf("https://%s:2380", nodeIP)
	logf("[5.3] Adding %s (%s) to etcd cluster...", etcdName, peerURL)
	addOut, addErr := etcdctlRun("member", "add", etcdName, "--peer-urls="+peerURL)
	if addErr != nil {
		lower := strings.ToLower(addOut + " " + addErr.Error())
		if strings.Contains(lower, "already exists") || strings.Contains(lower, "peer urls already exists") {
			logf("[5.3] peer URL already registered — continuing (partial join resume)")
		} else {
			return fmt.Errorf("etcd-join: member add: %s: %w", addOut, addErr)
		}
	} else {
		logf("[5.3] member add: %s", etcdName)
	}

	// Append this node to initial-cluster.
	if initialCluster != "" {
		initialCluster += ","
	}
	initialCluster += etcdName + "=" + peerURL

	// [5.4] Write etcd.yaml with initial-cluster-state: existing.
	// INVARIANT: initial-cluster-state MUST be "existing" for Day-1 joins.
	// Writing "new" on a joining node forks the etcd cluster and destroys quorum.
	logf("[5.4] Writing %s (initial-cluster-state: existing)...", yamlPath)
	etcdDataDir := filepath.Join(ctx.StateDir, "etcd")
	etcdYAML := fmt.Sprintf(`name: %q
data-dir: %q

listen-client-urls: "https://%s:2379"
advertise-client-urls: "https://%s:2379"
listen-peer-urls: "https://%s:2380"
initial-advertise-peer-urls: "https://%s:2380"

initial-cluster: %q
initial-cluster-state: "existing"
initial-cluster-token: "globular-etcd-cluster"

quota-backend-bytes: 8589934592
auto-compaction-mode: "periodic"
auto-compaction-retention: "1h"
snapshot-count: 10000

client-transport-security:
  cert-file: %q
  key-file: %q
  client-cert-auth: false
  auto-tls: false

peer-transport-security:
  cert-file: %q
  key-file: %q
  client-cert-auth: false
  trusted-ca-file: %q
  auto-tls: false

logger: "zap"
`,
		etcdName, etcdDataDir,
		nodeIP, nodeIP, nodeIP, nodeIP,
		initialCluster,
		cert, key,
		cert, key, caCert,
	)
	if err := os.MkdirAll(cfgDir, 0o750); err != nil {
		return fmt.Errorf("etcd-join: mkdir %s: %w", cfgDir, err)
	}
	if err := os.WriteFile(yamlPath, []byte(etcdYAML), 0o644); err != nil {
		return fmt.Errorf("etcd-join: write etcd.yaml: %w", err)
	}
	_ = exec.Command("chown", "globular:globular", yamlPath).Run()

	// Write etcd_endpoints for other services that dial etcd directly.
	bootstrapHost := etcdExtractHost(s.BootstrapEtcd)
	endpointsContent := fmt.Sprintf("https://%s:2379\nhttps://%s:2379\n", bootstrapHost, nodeIP)
	if err := os.WriteFile(endpointsPath, []byte(endpointsContent), 0o644); err != nil {
		logf("[5.4] write etcd_endpoints: %v (non-fatal)", err)
	} else {
		_ = exec.Command("chown", "globular:globular", endpointsPath).Run()
	}

	// [5.5] Start globular-etcd.service.
	logf("[5.5] Starting globular-etcd.service...")
	startOut, startErr := exec.Command("systemctl", "start", "globular-etcd.service").CombinedOutput()
	if startErr != nil {
		return fmt.Errorf("etcd-join: systemctl start globular-etcd: %s: %w",
			strings.TrimSpace(string(startOut)), startErr)
	}

	// [5.6] Poll local etcd health (60 s).
	logf("[5.6] Waiting for etcd to become healthy (60s)...")
	localEndpoint := fmt.Sprintf("https://%s:2379", nodeIP)
	etcdOK := false
	for i := 0; i < 30; i++ {
		healthCmd := exec.Command(etcdctlPath,
			"--endpoints="+localEndpoint,
			"--cacert="+caCert,
			"--cert="+cert,
			"--key="+key,
			"endpoint", "health",
		)
		healthCmd.Env = append(os.Environ(), "ETCDCTL_API=3")
		out, healthErr := healthCmd.CombinedOutput()
		if healthErr == nil && strings.Contains(string(out), "is healthy") {
			etcdOK = true
			break
		}
		time.Sleep(2 * time.Second)
	}
	if !etcdOK {
		if jOut, jErr := exec.Command("journalctl", "-u", "globular-etcd.service", "--no-pager", "-n", "40").CombinedOutput(); jErr == nil {
			logf("[etcd journal]\n%s", string(jOut))
		}
		return fmt.Errorf("etcd-join: etcd did not become healthy after 60s; if WAL is damaged, use --repair-etcd")
	}
	logf("[5.6] etcd healthy")

	// [5.7] Verify named member from bootstrap cluster — proves we joined the right cluster,
	// not a forked single-node cluster.
	logf("[5.7] Verifying member %q from bootstrap (%s)...", etcdName, s.BootstrapEtcd)
	memberCheck, _ := etcdctlRun("member", "list")
	if !strings.Contains(memberCheck, etcdName) {
		return fmt.Errorf("etcd-join: %q not visible from bootstrap cluster (%s); "+
			"local etcd may have forked — use --repair-etcd to retry", etcdName, s.BootstrapEtcd)
	}
	logf("[5.7] etcd member %q confirmed in cluster", etcdName)

	s.applied = true
	return nil
}

var etcdNonNameChar = regexp.MustCompile(`[^a-zA-Z0-9_-]`)

func etcdSanitizeName(hostname string) string {
	name := etcdNonNameChar.ReplaceAllString(hostname, "-")
	return strings.Trim(name, "-")
}

// etcdExtractLeaseID parses the lease ID from etcdctl output:
//
//	lease 694d5f03a400001e granted with TTL(300s)
func etcdExtractLeaseID(out string) string {
	re := regexp.MustCompile(`lease\s+(\S+)\s+granted`)
	m := re.FindStringSubmatch(out)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// etcdExtractHost extracts the host from a URL like "https://10.0.0.63:2379".
func etcdExtractHost(rawURL string) string {
	s := rawURL
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.Index(s, "/"); i >= 0 {
		s = s[:i]
	}
	if i := strings.LastIndex(s, ":"); i >= 0 {
		s = s[:i]
	}
	return s
}
