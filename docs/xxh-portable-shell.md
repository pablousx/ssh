# xxh Integration — Portable Shell Over SSH

## What is xxh?

`xxh` ("Bring Your Shell Wherever You Go") is a tool that uploads a portable shell binary
and your configuration to a remote server when you connect via SSH — **without requiring
root access or any pre-installed software on the remote**.

```
# Instead of:
ssh lever

# You get your full Zsh environment on the remote:
xxh lever +s zsh
```

## Why It Belongs Here

`xxh` sits at the intersection of your SSH project and your dotfiles:

- **This repo** decides *which hosts use xxh* and *how to connect* (port, identity, jump hosts).
- **`~/dotfiles`** decides *what shell environment to carry* (aliases, completions, p10k).

The `~/.ssh/config` entries this project manages are the natural place to define per-host
xxh behavior.

## Prerequisites

> [!IMPORTANT]
> xxh requires **native Linux `ssh`** to work. It does NOT work through the `ssh.exe` alias.
> Complete the Bitwarden WSL native bridge setup first:
> → [bitwarden-wsl-native-ssh.md](./bitwarden-wsl-native-ssh.md)

Once the bridge is set up and the `ssh.exe` aliases are removed, `xxh` works out of the box.

## Installation

```bash
# Install xxh via Homebrew (already in ~/dotfiles/setup.sh)
brew install xxh

# Install the Zsh shell plugin (downloads portable Zsh binary)
xxh +I xxh-shell-zsh
```

## Usage

### Basic connection
```bash
xxh lever +s zsh
```

### With agent forwarding (requires native SSH bridge)
```bash
xxh lever +s zsh -o ForwardAgent=yes
```

### First connection behavior
1. xxh uploads `~/.xxh/` bundle to the remote's `~/.xxh/` directory (~3MB, one-time).
2. Starts a Zsh session using the portable binary.
3. Subsequent connections reuse the uploaded environment (instant).

### Cleanup on remote
```bash
# To remove all xxh traces from a remote:
xxh lever +hhr
# Or manually:
ssh lever "rm -rf ~/.xxh"
```

## Integration with `~/.ssh/config`

You can configure per-host xxh defaults in an `~/.xxh/.xxhc` config file,
or use a wrapper function in your shell aliases.

### Example: Smart `ssh` wrapper (to add to `~/dotfiles/modules/aliases.zsh`)

```zsh
# SSH with optional xxh for unmanaged hosts
# Usage: ssh lever          → plain ssh (managed server, already has dotfiles)
#        ssh lever +xxh     → xxh with Zsh environment
function xxhh() {
    xxh "$1" +s zsh "${@:2}"
}
```

### Example: `~/.config/xxh/config.xxhc`

```toml
# xxh config — applies to all connections unless overridden
[hosts."*"]
+s = "zsh"
```

## When to Use xxh vs Plain SSH

| Scenario | Use |
| :--- | :--- |
| Server you **own** (VPS, homelab, cloud VM) | Plain `ssh` — your dotfiles are already installed via `~/dotfiles/setup.sh` |
| **Shared/managed server** you don't control | `xxh` — no root, no install, just connect |
| Quick one-off task on unknown server | `xxh` — instantly familiar environment |
| Server with restricted internet access | Plain `ssh` — xxh needs to upload ~3MB on first connect |

## Carrying Your Dotfiles Config

By default `xxh-shell-zsh` gives you a bare Zsh shell. To carry your specific aliases
and completions, you can create a custom xxh plugin that sources a lightweight subset
of your `~/dotfiles`:

**Planned lightweight config to carry:**
- `modules/aliases.zsh` (WSL-safe subset — excluding `ssh.exe` aliases)
- A stripped-down `.p10k.zsh` (no heavy async segments)
- Basic `zstyle` completion settings

> [!NOTE]
> This is planned work. The xxh plugin system uses `~/.xxh/.xxh/plugins/` directory.
> See [xxh plugin docs](https://github.com/xxh/xxh-plugin-zsh-znap) for how to create one.

## Roadmap

- [ ] Implement native SSH bridge (see [bitwarden-wsl-native-ssh.md](./bitwarden-wsl-native-ssh.md))
- [ ] Remove `ssh.exe` aliases from `linux/setup.sh` WSL branch
- [ ] Create `xxh-plugin-dotfiles` with lightweight alias + completion carry
- [ ] Add `xxhh` alias to `~/dotfiles/modules/aliases.zsh`
- [ ] Test: `xxh lever +s zsh` end-to-end with Bitwarden key authentication
- [ ] Document per-host targeting in `~/.config/xxh/config.xxhc`
