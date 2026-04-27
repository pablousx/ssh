# Bitwarden SSH Agent — Native Linux Bridge (WSL)

## The Problem

The current WSL setup works by aliasing `ssh` → `ssh.exe`, `scp` → `scp.exe`, etc.
This is reliable but has a cost:

- Tools like **`xxh`**, **`rsync`**, and **`git` native ops** only work with the real Linux `ssh` binary.
- **SSH agent forwarding** (`ssh -A`) doesn't work correctly through `ssh.exe`.
- Any Linux tooling that relies on `$SSH_AUTH_SOCK` (a Unix socket) is broken.

The root cause: Bitwarden exposes its SSH agent as a **Windows named pipe**
(`\\.\pipe\openssh-ssh-agent`), which the Linux kernel doesn't understand.

## The Solution: `npiperelay` + `socat`

Two tools bridge the gap:

| Tool | Role |
| :--- | :--- |
| **`npiperelay.exe`** | Windows binary that reads/writes a named pipe over stdio |
| **`socat`** | Linux tool that wraps that stdio stream in a Unix socket (`.sock`) |

Together they create a `$SSH_AUTH_SOCK` that native Linux `ssh` can use,
which secretly tunnels all requests to Bitwarden on the Windows side.

```
Linux ssh → $SSH_AUTH_SOCK (Unix socket) → socat → npiperelay.exe → Bitwarden named pipe
```

## Setup (Current Implementation)

The `linux/setup.sh` script now automatically configures this native bridge when it detects a WSL environment.

### Step 1: Install `socat` in WSL

```bash
sudo apt install socat -y
```

### Step 2: Download `npiperelay.exe`

1. Go to [github.com/jstarks/npiperelay/releases](https://github.com/jstarks/npiperelay/releases)
2. Download `npiperelay_windows_amd64.zip`
3. Extract `npiperelay.exe` somewhere on your Windows PATH, e.g. `C:\tools\npiperelay.exe`

Then symlink it into WSL:
```bash
sudo ln -s /mnt/c/tools/npiperelay.exe /usr/local/bin/npiperelay.exe
```

### Step 3: Verify Bitwarden is configured

In **Bitwarden Desktop** → Settings → **SSH Agent** → Enable ✅

The agent must be running for the bridge to connect.

### Step 4: Update `linux/setup.sh`

The WSL branch of `setup.sh` should write a native bridge instead of the `ssh.exe` aliases.

Replace the WSL block with:

```bash
# WSL-specific: Bridge Bitwarden SSH agent to native Linux ssh
export SSH_AUTH_SOCK="$HOME/.ssh/bitwarden-agent.sock"

if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
    rm -f "$SSH_AUTH_SOCK"
    (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \
        &>/dev/null &)
fi

alias sync-ssh='powershell.exe "Sync-SSH"'
```

> [!IMPORTANT]
> You can now **remove** the `ssh=ssh.exe`, `scp=scp.exe`, `sftp=sftp.exe` aliases
> and the `core.sshCommand = ssh.exe` git config. Native Linux `ssh` will work.

### Step 5: Verify

```bash
# Restart your shell, then:
ssh-add -l
# Should list your Bitwarden keys
```

## What This Unlocks

| Feature | Before (ssh.exe) | After (native bridge) |
| :--- | :---: | :---: |
| SSH agent works | ✅ | ✅ |
| `xxh` (portable shell) | ❌ | ✅ |
| SSH agent forwarding (`ssh -A`) | ❌ | ✅ |
| `rsync` native | ❌ | ✅ |
| `git` native SSH ops | ❌ | ✅ |
| Works when Bitwarden is closed | ❌ | ❌ (same — agent must be running) |

## Troubleshooting

**`ssh-add -l` returns "Could not open connection to agent"**
- Bitwarden is not running or SSH Agent is disabled in Bitwarden settings.
- Check if `socat` is still alive: `ps aux | grep socat`
- Check if socket exists: `ls -la ~/.ssh/bitwarden-agent.sock`

**Permission denied on socket**
- Remove the stale socket: `rm -f ~/.ssh/bitwarden-agent.sock` then restart your shell.

**`npiperelay.exe` not found**
- Ensure the symlink exists: `ls -la /usr/local/bin/npiperelay.exe`
- Or adjust the path in the `socat` command to the full `/mnt/c/tools/npiperelay.exe`.
