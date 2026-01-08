# SSH Config with Bitwarden

Automatically sync SSH keys from ssh-agent with Bitwarden metadata to create an organized SSH config file.

## What It Does

This tool bridges the gap between SSH keys in your ssh-agent and Bitwarden SSH key items:

1. **Reads SSH keys** from your ssh-agent (`ssh-add -L`)
2. **Fetches metadata** from Bitwarden (hostname, username) for each key
3. **Generates SSH config** with proper Host entries, automatically linking keys to their destinations
4. **Manages everything** in `~/ssh/` with a hard link to `~/.ssh/config`

No premium Bitwarden features required—uses public keys from ssh-agent instead of attachments.

## Quick Start

### Prerequisites

- PowerShell 7+
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw` command)
- SSH keys loaded in ssh-agent
- SSH key items in Bitwarden (type: SSH Key) with custom fields:
  - `HostName` - The server address
  - `User` - SSH username

### Setup

1. **Run setup** (adds Sync-SSH to your PowerShell profile):

   ```powershell
   .\setup.ps1
   ```

2. **Sync your keys**:

   ```powershell
   Sync-SSH
   ```

   Or run directly:

   ```powershell
   .\sync.ps1
   ```

3. **Connect** using the SSH key name from Bitwarden:
   ```powershell
   ssh keyname
   ```

## How It Works

### Bitwarden Setup

For each SSH key in Bitwarden, create an SSH Key item (type 5) with:

- **Name**: Matches your SSH key comment (from `ssh-add -L`)
- **Custom Fields**:
  - `HostName`: Server address (e.g., `example.com` or `192.168.1.100`)
  - `User`: SSH username (e.g., `ubuntu`, `root`)

### SSH Agent

Load your keys into ssh-agent:

```powershell
ssh-add C:\path\to\your\private\key
```

The key comment (last field in public key) must match the Bitwarden item name.

### Generated Config

The script creates entries like:

```
Host keyname
  HostName example.com
  User ubuntu
  IdentityFile C:\Users\Pablo\ssh\keys\keyname.pub
  IdentitiesOnly yes
```

## Files Structure

```
~/ssh/
├── sync.ps1         # Main sync script with Sync-SSH function
├── setup.ps1        # One-time PowerShell profile setup
├── config           # Generated SSH config (hard linked to ~/.ssh/config)
└── keys/            # Exported public keys
    └── *.pub        # Public key files
```

## Commands

- `Sync-SSH` - Sync keys and update config (available after setup)
- `.\sync.ps1` - Run sync directly
- `.\setup.ps1` - Add Sync-SSH to PowerShell profile

## Features

- ✅ No Bitwarden premium required
- ✅ Automatic Bitwarden vault unlock
- ✅ Hard link to `~/.ssh/config`
- ✅ Backup existing configs with timestamp
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
