# MinIO Setup for Globular Installer

The `setup-minio.sh` script is automatically called during the Day-0 installation process to configure MinIO with the necessary buckets and web assets.

## What it does

1. **Waits for MinIO to be ready** - Retries connection for up to 60 seconds
2. **Creates two buckets:**
   - `webroot` - Public read access for web content (HTML, images, etc.)
   - `users` - Private access for user files
3. **Uploads web assets to webroot:**
   - `index.html` - Globular cluster status and welcome page
   - `logo.png` - Globular logo

## Automatic Execution

The setup runs automatically during `install-day0.sh` after the bootstrap layer is installed. It is called between installing MinIO and installing the control plane services.

## Configuration

The script can be configured via environment variables:

```bash
export MINIO_ENDPOINT="127.0.0.1:9000"          # MinIO endpoint
export MINIO_ACCESS_KEY="minioadmin"            # MinIO access key
export MINIO_SECRET_KEY="minioadmin"            # MinIO secret key
export MINIO_USE_SSL="false"                    # Use SSL/TLS
```

## Setup Methods

The script tries multiple methods in order:

1. **MinIO Client (mc)** - Preferred method if `mc` is available on PATH
2. **Python boto3** - Falls back to Python if available
3. **Curl** - Limited functionality fallback (logs warning)

### Installing MinIO Client (Recommended)

```bash
# Linux
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# macOS
brew install minio/stable/mc
```

### Installing Python boto3

```bash
pip3 install boto3
```

## Manual Execution

To run the setup manually:

```bash
cd /path/to/globular-installer/scripts
./setup-minio.sh
```

Or with custom configuration:

```bash
MINIO_ENDPOINT="minio.example.com:9000" \
MINIO_ACCESS_KEY="admin" \
MINIO_SECRET_KEY="secret123" \
./setup-minio.sh
```

## Web Assets

The web assets are located in `internal/assets/webroot/`:

- **index.html** - Welcome page featuring:
  - Animated Globular logo
  - Cluster version and platform info
  - Configuration status (services, storage, mesh, etc.)
  - Quick links to health check, metrics, file browser
  - Responsive design with gradient styling

- **logo.png** - Globular logo image

## Accessing the Welcome Page

After installation, access the welcome page at:

```
http://<minio-endpoint>/webroot/index.html
```

Or through the gateway (if configured to serve from MinIO):

```
http://<gateway-endpoint>/
```

## Troubleshooting

### Setup fails with "MinIO not ready"
- Ensure MinIO service is running: `systemctl status globular-minio`
- Check MinIO is listening: `netstat -tuln | grep 9000`
- Increase retry timeout by modifying `MAX_RETRIES` in the script

### "Access denied" errors
- Verify credentials are correct
- Check MinIO logs: `journalctl -u globular-minio -f`
- Ensure MinIO admin credentials are properly configured

### Buckets not created
- Install MinIO Client (mc) or Python boto3
- Check the script output for specific error messages
- Manually verify MinIO is accessible: `curl http://localhost:9000/minio/health/live`

### Files not uploaded
- Verify files exist in `internal/assets/webroot/`
- Check file permissions
- Ensure sufficient disk space in MinIO data directory

## Skipping MinIO Setup

If you need to skip the MinIO setup during installation, you can:

1. Remove or rename the `setup-minio.sh` script
2. Remove execute permission: `chmod -x scripts/setup-minio.sh`
3. Set `SKIP_MINIO_SETUP=1` environment variable (if supported)

The installer will log a warning and continue without setting up MinIO.

## Integration with Gateway

The Globular gateway reads static web content from the MinIO `webroot` bucket when configured with MinIO as the object store backend. The welcome page serves as the default landing page for the cluster.

To configure the gateway to use MinIO:

1. Ensure MinIO contract is configured at `/var/lib/globular/objectstore/minio.json`
2. Set the bucket to `webroot` in the configuration
3. The gateway will automatically serve files from this bucket

## Development

To update the welcome page or logo:

1. Modify files in `internal/assets/webroot/`
2. Rebuild the installer (if assets are embedded)
3. Run the setup script to upload new files:
   ```bash
   ./scripts/setup-minio.sh
   ```

## Security Considerations

- The `webroot` bucket has public read access by design (for serving web content)
- The `users` bucket is private by default
- Change default MinIO credentials in production
- Use SSL/TLS in production environments (`MINIO_USE_SSL=true`)
- Consider using IAM roles or STS tokens instead of static credentials
