# Globular Installer

This repository contains the Globular installer and packaged service specs.

## Day-0 Cluster Bootstrap

To install a minimal control-plane cluster from packaged services:

```
sudo ./scripts/install-day0.sh
```

To fully remove the Day-0 control plane:

```
sudo ./scripts/uninstall-day0.sh
```

Both scripts resolve paths relative to the repository root and auto-detect the appropriate `globular-installer` CLI invocation. Run them from any directory; just ensure packaged tarballs are present under `internal/assets/packages/`.
