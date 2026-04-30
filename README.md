# 🔑 Bitwarden SSH Sync

**Sync your SSH keys from `ssh-agent` with Bitwarden metadata to create a perfectly organized SSH config.**
Works seamlessly on **Windows (PowerShell)**, **Native Linux (Bash/Zsh)**, and **WSL**.

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
- **WSL only**: `npiperelay.exe` — Binaries are not available, so you must **build it from source** (requires [Go](https://go.dev/doc/install)):
  ```bash
  # 1. Install Go (https://go.dev/doc/install)
  sudo apt update && sudo apt install golang-go -y

  # 2. Clone the repo
  git clone https://github.com/jstarks/npiperelay $HOME/npiperelay

  # 3. Build the Windows binary from WSL
  cd $HOME/npiperelay
  GOOS=windows go build -o /mnt/c/tools/npiperelay.exe .

  # 4. Symlink it into your WSL path
  sudo ln -s /mnt/c/tools/npiperelay.exe /usr/local/bin/npiperelay.exe
  ```

---

## 📥 Installation

### 1. Clone the Repository
```powershell
# In PowerShell or Bash
git clone https://github.com/pablousx/ssh $HOME/ssh
cd $HOME/ssh
```

---

### 💻 Windows Setup (Native)

1. **Run the setup script**:
   ```powershell
   cd $HOME/ssh/windows
   .\setup.ps1
   ```
2. **Reload your profile** (or restart PowerShell):
   ```powershell
   . $PROFILE
   ```
3. **Sync your keys**:
   ```powershell
   Sync-SSH
   ```

---

### 🐧 Linux & WSL Setup

The setup script detects if you are on **Native Linux** or **WSL** and configures your environment accordingly.

1. **Run the setup script**:
   ```bash
   cd ~/ssh/linux
   chmod +x setup.sh
   ./setup.sh
   ```
2. **Add to your shell profile** (usually `~/.zshrc` or `~/.bashrc`):
   ```bash
   # Add this line to the end of the file
   source ~/.ssh/sync-ssh-env.sh
   ```
3. **Apply changes and sync**:
   ```bash
   source ~/.zshrc  # or ~/.bashrc
   sync-ssh
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

### Prerequisite: `socat` + `npiperelay.exe` (WSL only)

See the [Prerequisites](#️-prerequisites) section above for installation instructions.

---


## 📂 Project Structure

```text
.
├── linux/
│   ├── setup.sh    # Environment-aware installer (Native vs WSL)
│   └── sync.sh     # Native Linux sync logic
├── windows/
│   ├── setup.ps1   # PowerShell profile configuration
│   └── sync.ps1    # Core sync logic (Shared by Win/WSL)
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
