# SSH Config with Bitwarden

Automatically sync SSH keys from ssh-agent with Bitwarden metadata to create an organized SSH config file. Works on Windows (PowerShell), Linux (Bash), and WSL.

## What It Does

This tool bridges the gap between SSH keys in your ssh-agent and Bitwarden SSH key items:

1. **Reads SSH keys** from your ssh-agent (`ssh-add -L`)
2. **Fetches metadata** from Bitwarden (hostname, username) for each key
3. **Generates SSH config** within a managed section, automatically linking keys to their destinations and updating existing entries
4. **Manages everything** in `~/ssh/` with a link to `~/.ssh/config`

No premium Bitwarden features required—uses public keys from ssh-agent instead of attachments.

## Quick Start

### Prerequisites

- [Bitwarden Desktop](https://bitwarden.com/download/)
   - Have ssh agent enabled in BitWarden Desktop settings. [Instructions](https://bitwarden.com/help/ssh-agent/)
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw` command)
   - [Be logged in to Bitwarden CLI](https://bitwarden.com/help/cli/#log-in): `bw login`
- `jq` (required for Linux/Bash version)
- Have SSH key items in Bitwarden (type: SSH Key) with custom fields:
  - `HostName` - The server address
  - `User` - SSH username

---

### Setup

1. **Clone the repository**:

  ```powershell
  git clone https://github.com/pablousx/ssh $HOME/ssh && cd $HOME/ssh
  ```

### Windows Setup

2. **Run setup** (adds Sync-SSH to your PowerShell profile):

   ```powershell
   cd $HOME/ssh/windows
   .\setup.ps1
   ```

3. **Reload PowerShell and Sync your keys**:

   ```powershell
   Sync-SSH
   ```

4. **Connect** using the SSH key name from Bitwarden:
   ```powershell
   ssh <keyname>
   ```

---

### Linux Setup

2. **Run setup** (adds `sync-ssh` alias to your `.bashrc` or `.zshrc`):
   ```bash
   cd $HOME/ssh/linux
   chmod +x setup.sh
   ./setup.sh
   ```

3. **Source your shell** and sync your keys:
   ```bash
   source ~/.bashrc
   sync-ssh
   ```

4. **Connect** using the SSH key name from Bitwarden:
   ```bash
   ssh <keyname>
   ```

---

## How It Works

### Bitwarden Setup

For each SSH key in Bitwarden, create an SSH Key item (type 5) with:

- **Name**: Matches your SSH key comment (from `ssh-add -L`)
- **Custom Fields**:
  - `HostName`: Server address (e.g., `example.com` or `192.168.1.100`)
  - `User`: SSH username (e.g., `ubuntu`, `root`)


The script manages a section in your `~/.ssh/config` file marked with:
`# --- START SYNC-SSH MANAGED SECTION ---`

It creates entries like:

```ssh
Host example
  HostName example.com
  User ubuntu
  IdentityFile ~/.ssh/keys/example.pub
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
- ✅ Cross-platform: Windows (PowerShell), Linux (Bash), and WSL
- ✅ Managed config block (safe for manual edits)
- ✅ Syncs updates and deletions from Bitwarden
- ✅ Idempotent—safe to run multiple times
