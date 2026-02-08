# Globular Conformance Test Suite

This directory contains executable tests that validate Globular v1.0 invariants.

## Purpose

The conformance suite ensures that:
- Fresh Day-0 installations meet all baseline requirements
- Day-1 operations maintain system invariants
- Regressions are caught before deployment

## Running Tests

```bash
# Run all conformance tests
./run.sh

# Run specific test
./10_dns_port_describe.sh

# Enable verbose output
VERBOSE=1 ./run.sh

# Run in CI mode (exit on first failure)
CI=1 ./run.sh
```

## Test Naming Convention

Tests are numbered to indicate execution order and grouping:
- `00-09`: Smoke tests (basic system checks)
- `10-19`: DNS service invariants
- `20-29`: TLS and certificate invariants
- `30-39`: File system and permission invariants
- `40-49`: System capability invariants

## Test Structure

Each test script:
1. **Sources**: `common.sh` for shared utilities
2. **Checks**: One or more invariants
3. **Reports**: Using `pass()` or `fail()` functions
4. **Exits**: With 0 (pass) or 1 (fail)

Example:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

test_name="My Test"

# Check something
if some_check; then
  pass "$test_name"
else
  fail "$test_name: expected X but got Y"
fi
```

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed
- `2`: Test suite error (missing dependencies, etc.)

## Test Output

Tests print:
- `✓ Test Name` on success
- `✗ Test Name: reason` on failure
- Diagnostic details when `VERBOSE=1`

## Environment Variables

- `VERBOSE=1`: Enable detailed output
- `CI=1`: Fail fast mode (exit on first failure)
- `STATE_DIR`: Override state directory (default: `/var/lib/globular`)
- `SKIP_SUDO`: Skip tests requiring sudo (for CI)

## Adding New Tests

1. Create test file: `NN_descriptive_name.sh`
2. Make executable: `chmod +x NN_descriptive_name.sh`
3. Follow test structure template
4. Add to `run.sh` in appropriate order
5. Document in `docs/v1-invariants.md`

## Integration with Installer

The Day-0 installer can run conformance tests automatically:
```bash
GLOBULAR_CONFORMANCE=1 ./scripts/install-day0.sh
```

Initially runs in warn-only mode (logs failures but doesn't fail installation).
Once stable, will fail installation on conformance failures.

## Related Documentation

- `docs/v1-invariants.md` - Detailed invariant specifications
- `docs/testing-strategy.md` - Overall testing approach
