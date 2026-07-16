# 🔑 Bitwarden SSH Sync

**Sync your SSH keys from `ssh-agent` with Bitwarden metadata to create a perfectly organized SSH config.**
Works seamlessly on **Windows (PowerShell)**, **Native Linux (Bash/Zsh)**, and **WSL**.

---

## 📌 Table of Contents

- [🚀 Why Bitwarden SSH Sync?](#-why-bitwarden-ssh-sync)
- [🛠️ Preparation: Bitwarden Setup](#️-preparation-bitwarden-setup)
- [⚙️ Prerequisites](#️-prerequisites)
- [📥 Installation](#-installation)
  - [Linux & WSL (One-Liner)](#-linux--wsl-one-liner)
  - [Windows Setup (Native)](#-windows-setup-native)
  - [Manual Installation (Advanced)](#️-manual-installation-advanced)
- [🗑️ Uninstallation](#️-uninstallation)
  - [Linux & WSL (One-Liner)](#-linux--wsl-one-liner-1)
  - [Windows (One-Liner)](#-windows-one-liner)
  - [Manual Uninstall](#️-manual-uninstall)
- [🧊 SSH Agent Integration](#-ssh-agent-integration)
- [📂 Project Structure](#-project-structure)
- [🔏 Git SSH Signing](#-git-ssh-signing)
- [❓ FAQ & Troubleshooting](#-faq--troubleshooting)

---

## 🚀 Why Bitwarden SSH Sync?

Managing multiple SSH keys and their corresponding hostnames/usernames is a pain. This tool automates the bridge between your **Bitwarden vault** and your **local SSH configuration**:

- ✅ **Automatic Mapping**: Links keys in your `ssh-agent` to Bitwarden items using their names/comments.
- ✅ **Metadata Sync**: Pulls `HostName` and `User` directly from Bitwarden custom fields.
- ✅ **Managed Config**: Safely updates a dedicated block in your `~/.ssh/config` without touching your manual entries.
- ✅ **WSL Native Integration**: Bridges WSL to the Windows SSH Agent so you only have to unlock your vault once.
- ✅ **No Premium Required**: Uses public key comments instead of paid Bitwarden file attachments.

---

## 🛠️ Preparation: Bitwarden Setup

To allow the sync to work, your Bitwarden items must be configured correctly.

1. **Create an SSH Key Item**: In Bitwarden, create a new item of type **SSH Key**.
2. **Name your item**: The **Name** you give the item in Bitwarden will automatically become your SSH `Host` alias (e.g., naming it `web-server` allows you to run `ssh web-server`).
3. **Add Custom Fields**:
   - `HostName`: The server's IP or domain (e.g., `1.2.3.4` or `app.example.com`).
   - `User`: Your SSH username (e.g., `ubuntu`).

---

## ⚙️ Prerequisites

- [Bitwarden Desktop](https://bitwarden.com/download/) (with [SSH Agent enabled](https://bitwarden.com/help/ssh-agent/))
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`)
  - Must be logged in: `bw login`
- `jq` (Required for **Linux & WSL**)
- `git`
- **WSL only**: `socat` (`sudo apt install socat -y`)
- **WSL only**: `npiperelay.exe` — You must use the patched version from `rupor-github` which fixes the Bitwarden disconnect crashes.:
  ```bash
  # 1. Download the latest release zip
  curl -sL https://github.com/rupor-github/wsl-ssh-agent/releases/latest/download/wsl-ssh-agent.zip -o /tmp/wsl-ssh-agent.zip

  # 2. Extract npiperelay.exe to a Windows path (e.g. C:\tools)
  mkdir -p /mnt/c/tools
  unzip -p /tmp/wsl-ssh-agent.zip npiperelay.exe > /mnt/c/tools/npiperelay.exe
  chmod +x /mnt/c/tools/npiperelay.exe

  # 3. Symlink it into your WSL path
  sudo ln -s /mnt/c/tools/npiperelay.exe /usr/local/bin/npiperelay.exe
  ```

---

## 📥 Installation

### 🐧 Linux & WSL (One-Liner)

Install automatically with a single command (no git clone required):

```bash
curl -fsSL https://raw.githubusercontent.com/pablousx/ssh/main/install.sh | sh
```

The installer will download the scripts, run the interactive setup, and automatically configure your shell profile (`.zshrc` or `.bashrc`).

> **💡 Post-Install**: To sync immediately, restart your shell or run `source ~/.ssh/sync-ssh-env.sh`, then run:
> ```bash
> sync-ssh
> ```

---

### 💻 Windows Setup (Native)

Install automatically with a single command (no git clone required):

```powershell
irm https://raw.githubusercontent.com/pablousx/ssh/main/install.ps1 | iex
```

The installer will download the scripts, run the interactive setup, and automatically configure your PowerShell profile.

> **Note**: If your Execution Policy is `Restricted`, you will need to allow scripts first:
> `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

> **💡 Post-Install**: To sync immediately, restart PowerShell or run `. $PROFILE`, then run:
> ```powershell
> Sync-SSH
> ```

---

### 🛠️ Manual Installation (Advanced)

If you prefer to clone the repository manually instead of using the one-liners:

**For Linux/WSL:**
```bash
git clone https://github.com/pablousx/ssh ~/ssh
cd ~/ssh/linux
chmod +x setup.sh
./setup.sh
```

**For Windows:**
```powershell
git clone https://github.com/pablousx/ssh $HOME/ssh
cd $HOME/ssh/windows
.\setup.ps1
```

---

## 🗑️ Uninstallation

### 🐧 Linux & WSL (One-Liner)

```bash
curl -fsSL https://raw.githubusercontent.com/pablousx/ssh/main/uninstall.sh | sh
```

### 💻 Windows (One-Liner)

```powershell
irm https://raw.githubusercontent.com/pablousx/ssh/main/uninstall.ps1 | iex
```

Both uninstallers will:
- Remove the auto-added line from your shell profile (`.zshrc`, `.bashrc`, `$PROFILE`, etc.)
- Delete the scripts from the install directory (`~/.local/share/sync-ssh` or `%LOCALAPPDATA%\sync-ssh`)
- Interactively ask whether to also:
  - Remove synced public keys from `~/.ssh/keys/`
  - Remove the managed block from `~/.ssh/config`
  - Remove global git config entries (`sync-ssh.*`)

### 🛠️ Manual Uninstall

**Linux/WSL — step by step:**

1. **Remove the source line** from your `~/.zshrc` / `~/.bashrc`:
   ```bash
   # Delete the two lines that were added by setup:
   # "# Added by Bitwarden SSH Sync setup"
   # "source ~/.ssh/sync-ssh-env.sh"
   ```
2. **Remove the env file**:
   ```bash
   rm -f ~/.ssh/sync-ssh-env.sh
   ```
3. **Remove the install directory** (one-liner install only):
   ```bash
   rm -rf ~/.local/share/sync-ssh
   ```
4. **Remove synced keys** *(optional)*:
   ```bash
   rm -rf ~/.ssh/keys
   ```
5. **Remove the managed SSH config block** *(optional)* — delete everything between and including:
   ```
   # --- START SYNC-SSH MANAGED SECTION ---
   # --- END SYNC-SSH MANAGED SECTION ---
   ```
6. **Remove global git config** *(optional)*:
   ```bash
   git config --global --unset sync-ssh.commit-signing
   git config --global --unset sync-ssh.keep-alive
   git config --global --unset sync-ssh.agent-mode
   ```

**Windows — step by step:**

1. **Remove the dot-source line** from your PowerShell profile (`$PROFILE`):
   ```powershell
   # Open your profile:
   notepad $PROFILE
   # Delete the line that looks like:
   # . "C:\Users\<you>\AppData\Local\sync-ssh\sync.ps1"
   ```
2. **Remove the install directory**:
   ```powershell
   Remove-Item -Recurse -Force "$env:LOCALAPPDATA\sync-ssh"
   ```
3. **Remove synced keys** *(optional)*:
   ```powershell
   Remove-Item -Recurse -Force "$HOME\.ssh\keys"
   ```
4. **Remove the managed SSH config block** *(optional)* — open `~\.ssh\config` and delete everything between and including:
   ```
   # --- START SYNC-SSH MANAGED SECTION ---
   # --- END SYNC-SSH MANAGED SECTION ---
   ```
5. **Remove global git config** *(optional)*:
   ```powershell
   git config --global --unset sync-ssh.commit-signing
   git config --global --unset sync-ssh.keep-alive
   git config --global --unset sync-ssh.agent-mode
   ```

---


## 🧊 SSH Agent Integration

### 🐧 Native Linux
On Native Linux, the Bitwarden Desktop app can act as your SSH agent.
- **Enabling**: Open Bitwarden Desktop → Settings → SSH Agent → Enable.
- **Socket**: The agent typically creates a socket at `~/.bitwarden-ssh-agent.sock`.
- **Setup**: Our `setup.sh` script automatically exports the `SSH_AUTH_SOCK` variable in `~/.ssh/sync-ssh-env.sh` so your terminal can find it.

### 🪟 WSL (Windows Subsystem for Linux)
WSL cannot directly access the Windows SSH agent named pipe. We use a **Unix socket bridge** to connect them.

**How it works:**
The setup script configures a background `socat` process that forwards a local Unix socket (`~/.bitwarden-ssh-agent.sock`) to the Windows SSH agent via `npiperelay.exe`.

```
Linux ssh → $SSH_AUTH_SOCK (~/.bitwarden-ssh-agent.sock) → socat → npiperelay.exe → Bitwarden Pipe
```

This bridge allows native Linux tools like `xxh`, `rsync`, and `git` to use your Bitwarden keys without re-authenticating.

| Feature | Status |
| :--- | :---: |
| SSH agent works | ✅ |
| `xxh` (portable shell) | ✅ |
| SSH agent forwarding (`-A`) | ✅ |
| `rsync` native | ✅ |
| `git` native SSH ops | ✅ |
| Works when Bitwarden is closed | ❌ |

> **💡 Note on connection drops:**
> If the Bitwarden Desktop app is restarted or updated, the WSL bridge connection might drop. You can instantly recover it by running `reset-ssh-agent` in your terminal, which will recreate the `socat` bridge without needing to restart your WSL instance.

### Prerequisite: `socat` + `npiperelay.exe` (WSL only)

See the [Prerequisites](#️-prerequisites) section above for installation instructions.

---


## 📂 Project Structure

```text
.
├── install.sh      # Linux/WSL one-liner entry-point
├── install.ps1     # Windows one-liner entry-point
├── uninstall.sh    # Linux/WSL uninstaller
├── uninstall.ps1   # Windows uninstaller
├── linux/
│   ├── setup.sh    # Environment-aware installer (Native vs WSL)
│   └── sync.sh     # Native Linux sync logic
├── windows/
│   ├── setup.ps1   # PowerShell profile configuration
│   └── sync.ps1    # Core sync logic
└── README.md
```

---

## 🔏 Git SSH Signing

You can use your Bitwarden-managed SSH keys to cryptographically sign your Git commits.

### Setup
1. Name your Bitwarden SSH Key item exactly `git-sign`.
2. **Optional**: Add a Custom Field named `Email` (or `GitEmail`) in Bitwarden if you want to use a specific email address for commit verification.
3. Run the sync script (`sync-ssh` on Linux/WSL or `Sync-SSH` on Windows).

The script will automatically:
- Fetch the public key directly from Bitwarden (no host metadata or SSH Agent matching required).
- Configure Git globally to use SSH signing.
- Set `user.signingkey` to the synced public key.
- Update your `~/.ssh/allowed_signers` file with your Bitwarden `Email` field (or fall back to Git global user email).


---

## ❓ FAQ & Troubleshooting

**Q: `sync-ssh` says "No keys found in ssh-agent"**
A: Ensure your Bitwarden Vault is unlocked and the "SSH Agent" feature is enabled in Bitwarden Desktop settings. Run `ssh-add -L` to verify keys are visible.

**Q: How do I connect to a synced host?**
A: Use the **Host alias**, which is a sanitized version of your SSH key comment (lowercase, alphanumeric with dashes).
Example: A key with comment `My Server (Prod)` becomes `ssh my-server--prod-`.

**Q: Where are the public keys stored?**
A: They are exported to `~/.ssh/keys/*.pub`. These are just "pointers" that tell your SSH client which key to request from the Bitwarden agent.

**Q: Can I still add manual entries to my config?**
A: Yes! The script only manages the block between the `# --- START/END SYNC-SSH ---` markers. Anything outside that block is safe.
