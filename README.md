# SSH Config with Bitwarden

Automatically sync SSH keys from ssh-agent with Bitwarden metadata to create an organized SSH config file. Works on Windows (PowerShell) and Linux (Bash).

## What It Does

This tool bridges the gap between SSH keys in your ssh-agent and Bitwarden SSH key items:

1. **Reads SSH keys** from your ssh-agent (`ssh-add -L`)
2. **Fetches metadata** from Bitwarden (hostname, username) for each key
3. **Generates SSH config** within a managed section, automatically linking keys to their destinations and updating existing entries
4. **Manages everything** in `~/ssh/` with a link to `~/.ssh/config`

No premium Bitwarden features required—uses public keys from ssh-agent instead of attachments.

## Quick Start

### Prerequisites

- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw` command)
- Be logged in to Bitwarden: `bw login`
- `jq` (required for Linux/Bash version)
- SSH keys loaded in ssh-agent
- SSH key items in Bitwarden (type: SSH Key) with custom fields:
  - `HostName` - The server address
  - `User` - SSH username

---

### Windows Setup

1. **Run setup** (adds Sync-SSH to your PowerShell profile):
   ```powershell
   cd windows
   .\setup.ps1
   ```

2. **Sync your keys**:
   ```powershell
   Sync-SSH
   ```

---

### Linux Setup

1. **Run setup** (adds `sync-ssh` alias to your `.bashrc` or `.zshrc`):
   ```bash
   cd linux
   chmod +x setup.sh
   ./setup.sh
   ```

2. **Sync your keys**:
   ```bash
   sync-ssh
   ```

---

## How It Works

### Bitwarden Setup

For each SSH key in Bitwarden, create an SSH Key item (type 5) with:

- **Name**: Matches your SSH key comment (from `ssh-add -L`)
- **Custom Fields**:
  - `HostName`: Server address (e.g., `example.com` or `192.168.1.100`)
  - `User`: SSH username (e.g., `ubuntu`, `root`)

### SSH Agent

Load your keys into ssh-agent:

```bash
# Linux
ssh-add /path/to/your/private/key

# Windows (PowerShell)
ssh-add C:\path\to\your\private\key
```

The key comment (last field in public key) must match the Bitwarden item name.

The script manages a section in your config file marked with:
`# --- START SYNC-SSH MANAGED SECTION ---`

It creates entries like:

```ssh
Host keyname
  HostName example.com
  User ubuntu
  IdentityFile ~/.ssh/keys/keyname.pub
  IdentitiesOnly yes
```

## Files Structure

```
.
├── windows/
│   ├── sync.ps1         # Windows sync script
│   └── setup.ps1        # PowerShell profile setup
└── linux/
    ├── sync.sh          # Linux sync script (Bash)
    └── setup.sh         # Linux setup script
```

## Features

- ✅ No Bitwarden premium required
- ✅ Automatic Bitwarden vault unlock
- ✅ Cross-platform: Windows (PowerShell) and Linux (Bash)
- ✅ Hard link (Windows) or Symbolic link (Linux) to `~/.ssh/config`
- ✅ Managed config block (safe for manual edits)
- ✅ Syncs updates and deletions from Bitwarden
- ✅ Idempotent—safe to run multiple times
- ✅ Global command via PowerShell profile

## Troubleshooting

**"Could not retrieve keys from SSH agent"**

- Ensure ssh-agent is running: `Get-Service ssh-agent`
- Load keys: `ssh-add C:\path\to\key`

**"Bitwarden Vault: locked"**

- Script will prompt for master password automatically

**Keys not matching**

- Verify SSH key comment matches Bitwarden item name
- Check with: `ssh-add -L` (last field is the comment)
