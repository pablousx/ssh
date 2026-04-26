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
- `jq` (Required for **Native Linux** only)
- `git`

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

## 🧊 WSL Support (Windows Subsystem for Linux)

WSL handles SSH differently to ensure seamless integration with your Windows environment.

> [!IMPORTANT]
> **For WSL**, you should complete the **Windows Setup** first, then run the **Linux Setup** inside your WSL distro.

- **Windows Agent Bridge**: WSL cannot natively access the Bitwarden SSH agent pipe. The setup script fixes this by aliasing `ssh`, `ssh-add`, and `git` to use their Windows versions (`ssh.exe`, etc.) directly. This allows you to use the keys loaded in your Windows Bitwarden instance from within Linux.
- **Cross-Sync**: Running `sync-ssh` in WSL actually triggers the Windows PowerShell logic. This ensures your SSH configuration is synchronized in your Windows user profile, which is what the `ssh.exe` binaries use.
- **Identity Files**: For each key, a `.pub` file is created in `~/.ssh/keys/` (or the Windows equivalent). These files are used in your config as `IdentityFile` entries, which tells SSH to look for the matching private key inside the agent.

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
