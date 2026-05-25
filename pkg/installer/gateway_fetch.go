package installer

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// FetchPackagesFromGateway downloads all .tgz package files listed at
// ${gatewayURL}/join/packages/ into destDir.  Files already present are
// skipped (idempotent).  Returns the paths of every file present in destDir
// after the fetch (both newly downloaded and pre-existing).
func FetchPackagesFromGateway(gatewayURL, caCertPath, destDir string, log func(string)) ([]string, error) {
	if log == nil {
		log = func(string) {}
	}
	client, err := newGatewayHTTPClient(caCertPath)
	if err != nil {
		return nil, fmt.Errorf("build HTTP client: %w", err)
	}

	listURL := strings.TrimRight(gatewayURL, "/") + "/join/packages/"
	log("listing packages from " + listURL)
	resp, err := client.Get(listURL)
	if err != nil {
		return nil, fmt.Errorf("list packages: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list packages: HTTP %d from %s", resp.StatusCode, listURL)
	}

	var names []string
	if err := json.NewDecoder(resp.Body).Decode(&names); err != nil {
		return nil, fmt.Errorf("decode package list: %w", err)
	}
	if len(names) == 0 {
		log("gateway returned empty package list")
		return nil, nil
	}

	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return nil, fmt.Errorf("create dest dir %s: %w", destDir, err)
	}

	var result []string
	for _, name := range names {
		name = strings.TrimSpace(name)
		if !strings.HasSuffix(name, ".tgz") {
			continue
		}
		dest := filepath.Join(destDir, name)
		if _, err := os.Stat(dest); err == nil {
			log("  " + name + " already present — skip")
			result = append(result, dest)
			continue
		}
		fileURL := strings.TrimRight(gatewayURL, "/") + "/join/packages/" + name
		log("  downloading " + name + "...")
		if err := gatewayDownloadFile(client, fileURL, dest); err != nil {
			return nil, fmt.Errorf("download %s: %w", name, err)
		}
		log("  " + name + " done")
		result = append(result, dest)
	}
	return result, nil
}

// FetchWorkflowsFromGateway downloads all workflow YAML files listed at
// ${gatewayURL}/join/workflows/ into destDir.  Files already present are
// skipped (idempotent).
func FetchWorkflowsFromGateway(gatewayURL, caCertPath, destDir string, log func(string)) ([]string, error) {
	if log == nil {
		log = func(string) {}
	}
	client, err := newGatewayHTTPClient(caCertPath)
	if err != nil {
		return nil, fmt.Errorf("build HTTP client: %w", err)
	}

	listURL := strings.TrimRight(gatewayURL, "/") + "/join/workflows/"
	log("listing workflows from " + listURL)
	resp, err := client.Get(listURL)
	if err != nil {
		return nil, fmt.Errorf("list workflows: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list workflows: HTTP %d from %s", resp.StatusCode, listURL)
	}

	var names []string
	if err := json.NewDecoder(resp.Body).Decode(&names); err != nil {
		return nil, fmt.Errorf("decode workflow list: %w", err)
	}
	if len(names) == 0 {
		log("gateway returned empty workflow list")
		return nil, nil
	}

	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return nil, fmt.Errorf("create dest dir %s: %w", destDir, err)
	}

	var result []string
	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		dest := filepath.Join(destDir, name)
		if _, err := os.Stat(dest); err == nil {
			log("  " + name + " already present — skip")
			result = append(result, dest)
			continue
		}
		fileURL := strings.TrimRight(gatewayURL, "/") + "/join/workflows/" + name
		log("  downloading " + name + "...")
		if err := gatewayDownloadFile(client, fileURL, dest); err != nil {
			return nil, fmt.Errorf("download %s: %w", name, err)
		}
		log("  " + name + " done")
		result = append(result, dest)
	}
	return result, nil
}

func newGatewayHTTPClient(caCertPath string) (*http.Client, error) {
	tlsCfg := &tls.Config{}
	if caCertPath != "" {
		ca, err := os.ReadFile(caCertPath)
		if err != nil {
			return nil, fmt.Errorf("read CA cert %s: %w", caCertPath, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(ca) {
			return nil, fmt.Errorf("parse CA cert from %s", caCertPath)
		}
		tlsCfg.RootCAs = pool
	}
	return &http.Client{
		Transport: &http.Transport{TLSClientConfig: tlsCfg},
	}, nil
}

func gatewayDownloadFile(client *http.Client, url, dest string) error {
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}
	tmp := dest + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}
