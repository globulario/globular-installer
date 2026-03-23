package hostsblock

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// HostEntry represents a hosts file entry with an IP and associated names
type HostEntry struct {
	IP    string   // IP address (IPv4 or IPv6)
	Names []string // Hostnames/aliases for this IP
}

// EnsureManagedBlock ensures a managed block exists in the hosts file with the given entries.
// The block is identified by blockName and is surrounded by BEGIN/END markers.
// If the block exists, its contents are replaced. If not, it's appended to the file.
// This operation is idempotent and atomic (write to temp file, fsync, rename).
//
// Parameters:
//   - path: Path to hosts file (typically /etc/hosts)
//   - blockName: Unique identifier for this managed block (e.g., cluster domain)
//   - entries: List of host entries to write in the block
//
// Returns error if:
//   - File cannot be read or written
//   - Duplicate names exist within the managed block entries
//   - File permissions cannot be preserved
func EnsureManagedBlock(path string, blockName string, entries []HostEntry) error {
	if err := validateEntries(entries); err != nil {
		return fmt.Errorf("invalid entries: %w", err)
	}

	// Read current file
	fileInfo, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat hosts file: %w", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read hosts file: %w", err)
	}

	// Parse existing content
	lines := strings.Split(string(content), "\n")

	// Ensure file ends with newline (handle gracefully if it doesn't)
	endsWithNewline := len(content) > 0 && content[len(content)-1] == '\n'
	if !endsWithNewline && len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1] // Remove empty last line
	}

	// Find existing managed block
	beginMarker := fmt.Sprintf("# BEGIN GLOBULAR MANAGED HOSTS (%s)", blockName)
	endMarker := fmt.Sprintf("# END GLOBULAR MANAGED HOSTS (%s)", blockName)

	beginIdx := -1
	endIdx := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == beginMarker {
			beginIdx = i
		} else if strings.TrimSpace(line) == endMarker {
			endIdx = i
			break
		}
	}

	// Build new managed block content
	newBlock := buildManagedBlock(blockName, entries)

	var newLines []string
	if beginIdx >= 0 && endIdx >= 0 {
		// Replace existing block
		newLines = append(newLines, lines[:beginIdx]...)
		newLines = append(newLines, newBlock...)
		if endIdx+1 < len(lines) {
			newLines = append(newLines, lines[endIdx+1:]...)
		}
	} else {
		// Append new block
		newLines = append(newLines, lines...)

		// Ensure there's exactly one blank line before the new block if file is non-empty
		if len(newLines) > 0 && strings.TrimSpace(newLines[len(newLines)-1]) != "" {
			newLines = append(newLines, "")
		}

		newLines = append(newLines, newBlock...)
	}

	// Ensure final newline
	newContent := strings.Join(newLines, "\n")
	if !strings.HasSuffix(newContent, "\n") {
		newContent += "\n"
	}

	// Atomic write: write to temp file, fsync, rename
	tmpPath := path + ".tmp"
	if err := writeAtomic(tmpPath, path, []byte(newContent), fileInfo.Mode()); err != nil {
		return fmt.Errorf("atomic write: %w", err)
	}

	return nil
}

// RemoveManagedBlock removes a managed block from the hosts file.
// If the block doesn't exist, this is a no-op (idempotent).
// The operation is atomic (write to temp file, fsync, rename).
//
// Parameters:
//   - path: Path to hosts file (typically /etc/hosts)
//   - blockName: Unique identifier for the managed block to remove
//
// Returns error if file cannot be read or written.
func RemoveManagedBlock(path string, blockName string) error {
	fileInfo, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat hosts file: %w", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read hosts file: %w", err)
	}

	lines := strings.Split(string(content), "\n")

	// Find managed block
	beginMarker := fmt.Sprintf("# BEGIN GLOBULAR MANAGED HOSTS (%s)", blockName)
	endMarker := fmt.Sprintf("# END GLOBULAR MANAGED HOSTS (%s)", blockName)

	beginIdx := -1
	endIdx := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == beginMarker {
			beginIdx = i
		} else if strings.TrimSpace(line) == endMarker {
			endIdx = i
			break
		}
	}

	// If block doesn't exist, nothing to do
	if beginIdx < 0 || endIdx < 0 {
		return nil
	}

	// Remove block (including markers)
	var newLines []string
	newLines = append(newLines, lines[:beginIdx]...)
	if endIdx+1 < len(lines) {
		newLines = append(newLines, lines[endIdx+1:]...)
	}

	// Remove trailing empty lines that were before the block
	for len(newLines) > 0 && strings.TrimSpace(newLines[len(newLines)-1]) == "" {
		newLines = newLines[:len(newLines)-1]
	}

	// Ensure final newline
	newContent := strings.Join(newLines, "\n")
	if len(newContent) > 0 && !strings.HasSuffix(newContent, "\n") {
		newContent += "\n"
	}

	// Atomic write
	tmpPath := path + ".tmp"
	if err := writeAtomic(tmpPath, path, []byte(newContent), fileInfo.Mode()); err != nil {
		return fmt.Errorf("atomic write: %w", err)
	}

	return nil
}

// buildManagedBlock constructs the managed block lines (including markers)
func buildManagedBlock(blockName string, entries []HostEntry) []string {
	var lines []string

	lines = append(lines, fmt.Sprintf("# BEGIN GLOBULAR MANAGED HOSTS (%s)", blockName))

	for _, entry := range entries {
		if len(entry.Names) > 0 {
			line := fmt.Sprintf("%s %s", entry.IP, strings.Join(entry.Names, " "))
			lines = append(lines, line)
		}
	}

	lines = append(lines, fmt.Sprintf("# END GLOBULAR MANAGED HOSTS (%s)", blockName))

	return lines
}

// validateEntries checks for duplicate names within the entries
func validateEntries(entries []HostEntry) error {
	seen := make(map[string]bool)

	for _, entry := range entries {
		for _, name := range entry.Names {
			if seen[name] {
				return fmt.Errorf("duplicate hostname: %s", name)
			}
			seen[name] = true
		}
	}

	return nil
}

// writeAtomic performs an atomic file write:
// 1. Write to temp file
// 2. Fsync temp file
// 3. Rename temp file to target
// This ensures the file is never left in a partially-written state.
func writeAtomic(tmpPath, targetPath string, data []byte, perm os.FileMode) error {
	// Write to temp file
	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}

	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("write temp file: %w", err)
	}

	// Fsync to ensure data is on disk
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("fsync temp file: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("close temp file: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpPath, targetPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename temp file: %w", err)
	}

	return nil
}

// ParseHostsFile parses a hosts file and returns all entries.
// This is useful for testing and debugging.
func ParseHostsFile(path string) ([]HostEntry, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open hosts file: %w", err)
	}
	defer file.Close()

	var entries []HostEntry
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse: <ip> <name1> [name2] [name3] ...
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}

		entries = append(entries, HostEntry{
			IP:    fields[0],
			Names: fields[1:],
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan hosts file: %w", err)
	}

	return entries, nil
}
