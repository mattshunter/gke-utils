# GKE Scripts - Requirements

## Required Tools

The following tools **must** be installed for the scripts to work:

### 1. Google Cloud SDK (gcloud)
```bash
# Install on macOS
brew install google-cloud-sdk

# Install on Linux
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
```

### 2. kubectl
```bash
# Install on macOS
brew install kubectl

# Install on Linux (Debian/Ubuntu)
sudo apt-get install -y kubectl

# Install on Linux (RHEL/CentOS)
sudo yum install -y kubectl
```

### 3. GKE Authentication Plugin
```bash
gcloud components install gke-gcloud-auth-plugin
```
**Documentation**: https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl

### 4. OpenSSL
```bash
# Usually pre-installed on macOS and Linux
# Verify with:
openssl version

# Install if needed:
# macOS
brew install openssl

# Linux (Debian/Ubuntu)
sudo apt-get install openssl

# Linux (RHEL/CentOS)
sudo yum install openssl
```

### 5. base64
**Pre-installed** on all macOS and Linux systems as part of coreutils.

### 6. Standard Unix Utilities
The following are **pre-installed** on all Unix-like systems:
- `grep`
- `sed`
- `cut`
- `tr`
- `wc`
- `sort`
- `awk`

## Optional Tools

### jq
Required for:
- `gke-cert-check.sh` (with `--verify` flag for deployment discovery)
- `gke-diagnose-probes.sh` (for parsing JSON output)
- `gke-diagnose-shutdown.sh` (for analyzing pod configurations)

```bash
# Install on macOS
brew install jq

# Install on Linux (Debian/Ubuntu)
sudo apt-get install jq

# Install on Linux (RHEL/CentOS)
sudo yum install jq
```

**Note**: Some scripts will show a warning or error if `jq` is not installed when required.

### Node.js and npm
Required for installing `tty-table` (optional enhancement for `gke-restart-status.sh`).

```bash
# Install on macOS
brew install node

# Install on Linux (Debian/Ubuntu)
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install on Linux (RHEL/CentOS)
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
sudo yum install -y nodejs

# Verify installation
node --version
npm --version
```

**Note**: Node.js installation includes npm automatically.

### tty-table
Optional tool for enhanced table formatting in `gke-restart-status.sh`.

```bash
# Install via npm (requires Node.js)
npm install -g tty-table
```

**Note**: If not installed, the script falls back to `column` command.

### column
Optional tool for table formatting (usually pre-installed on macOS/Linux).

Used by:
- `gke-restart-status.sh` (fallback if `tty-table` not available)
- `gke-diagnose-evictions.sh` (for formatting output tables)

Usually pre-installed as part of `util-linux` package on Linux or BSD utilities on macOS.

### xpanes
Required for `gke-view-logs.sh` to create split-pane log viewer.

```bash
# Install on macOS
brew install xpanes

# Install on Linux
# See installation instructions at: https://github.com/greymd/tmux-xpanes
# Option 1: Download binary
curl -L https://raw.githubusercontent.com/greymd/tmux-xpanes/master/bin/xpanes -o ~/.local/bin/xpanes
chmod +x ~/.local/bin/xpanes

# Option 2: Clone repository
git clone https://github.com/greymd/tmux-xpanes.git
cd tmux-xpanes
sudo make install
```

**Note**: `xpanes` requires `tmux` to be installed (see below).

### tmux
Required as a dependency for `xpanes` (used by `gke-logs-xpanes.sh`).

```bash
# Install on macOS
brew install tmux

# Install on Linux (Debian/Ubuntu)
sudo apt-get install tmux

# Install on Linux (RHEL/CentOS)
sudo yum install tmux

# Verify installation
tmux -V
```

**Note**: `tmux` is a terminal multiplexer that allows split-pane viewing.

## Verification Commands

Run these commands to verify all required tools are installed:

```bash
# Core tools (required)
gcloud version
kubectl version --client
gke-gcloud-auth-plugin --version
openssl version
base64 --version

# Optional tools
jq --version
node --version
npm --version
tty-table --version
tmux -V
xpanes --version
```

## Authentication Requirements

Before running the script, ensure you're authenticated:

```bash
# Authenticate with Google Cloud
gcloud auth login

# Or use the script's --auto-login flag
./gke-cert-check.sh --auto-login [other options]
```

## Permissions Requirements

Your Google Cloud account needs:
- **GCP Project**: Viewer or Editor role
- **GKE Cluster**: Container Engine Developer or Kubernetes Engine Cluster Viewer
- **Kubernetes**: Permission to read secrets in the target namespace

To verify permissions:
```bash
# Check GCP permissions
gcloud projects get-iam-policy PROJECT_NAME --flatten="bindings[].members" --filter="bindings.members:user:YOUR_EMAIL"

# Check Kubernetes permissions
kubectl auth can-i get secrets --namespace=NAMESPACE
```

## Troubleshooting

### "No certificate found in secret"
This error typically occurs when:
1. The secret doesn't contain certificate data in expected fields (`tls.crt`, `ca.crt`, `cert.pem`, `certificate`)
2. The secret exists but is not a certificate secret
3. You don't have permission to read the secret's data

The script will show you what fields are available in the secret to help diagnose the issue.

### Authentication Expired
If you see "Failed to set GCP project" errors:
1. Your gcloud authentication may have expired
2. Run `gcloud auth login` to re-authenticate
3. Or use the `--auto-login` flag with the script

### Missing gke-gcloud-auth-plugin
Error: "gke-gcloud-auth-plugin is required but not installed"
- Install with: `gcloud components install gke-gcloud-auth-plugin`
- More info: https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl

## Platform Differences

### macOS and Linux
The scripts are compatible with both **macOS** and **Linux**. They automatically detect your OS and adjust date command syntax accordingly:

- **macOS**: Uses BSD `date` command syntax
- **Linux**: Uses GNU `date` command syntax

No manual configuration needed.

### Windows (WSL - Windows Subsystem for Linux)

The scripts work on **Windows Subsystem for Linux (WSL)**, but require some additional setup:

#### 1. Install WSL 2
```powershell
# Run in PowerShell as Administrator
wsl --install
```

Restart your computer after installation.

#### 2. Install Required Tools in WSL
Once inside your WSL terminal (Ubuntu/Debian):

```bash
# Update package lists
sudo apt-get update

# Install required tools
sudo apt-get install -y kubectl jq openssl

# Install Google Cloud SDK
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Install GKE auth plugin
gcloud components install gke-gcloud-auth-plugin

# Optional: Install Node.js and npm for tty-table
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
npm install -g tty-table

# Install tmux and xpanes for gke-logs-xpanes.sh
sudo apt-get install -y tmux
curl -L https://raw.githubusercontent.com/greymd/tmux-xpanes/master/bin/xpanes -o ~/.local/bin/xpanes
chmod +x ~/.local/bin/xpanes
# Make sure ~/.local/bin is in your PATH
export PATH="$HOME/.local/bin:$PATH"
```

#### 3. WSL-Specific Considerations

**File Permissions:**
- Scripts must have execute permissions: `chmod +x *.sh`
- Line endings must be Unix-style (LF, not CRLF)
  ```bash
  # Convert line endings if needed
  dos2unix *.sh
  # Or install dos2unix: sudo apt-get install dos2unix
  ```

**Accessing Files:**
- WSL can access Windows files at `/mnt/c/`, `/mnt/d/`, etc.
- Best practice: Keep scripts in WSL filesystem (`~/`) for better performance

**Browser Integration:**
- `gke-swagger-launch.sh` browser opening works differently in WSL
- May need to manually copy URL and paste in Windows browser
- Or install wslu: `sudo apt-get install wslu` for `wslview` command

**Authentication:**
- `gcloud auth login` will open browser in Windows
- Works seamlessly if WSL 2 is configured correctly

#### 4. Verification in WSL
```bash
# Verify all tools are installed
gcloud version
kubectl version --client
gke-gcloud-auth-plugin --version
openssl version
jq --version

# Check WSL version (should be WSL 2)
wsl --version  # Run in PowerShell
```

**Note**: WSL 1 is not recommended - upgrade to WSL 2 for better compatibility.
