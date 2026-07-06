# dotfiles

Watch the walkthrough: https://youtu.be/5N-okeDdIuI

My personal Mac setup, managed with nix-darwin and home-manager.
One repo, one command, and a fresh Mac ends up configured the same way every time.

## What you get

Running the switch builds:

- System settings (dark mode, key repeat, dock, Finder, trackpad)
- Homebrew apps (casks and CLI tools)
- Nix user packages (ripgrep, fd, fzf, jq, lazygit, Neovim, Hack Nerd Font)
- Shell (zsh, aliases, starship prompt)
- Editor (Neovim config)
- Terminal (WezTerm config)
- Agent configs (Claude, Codex, opencode all share one AGENTS.md)

## Prerequisites

- Apple Silicon Mac, by default.
- Intel Mac: change one line.
  In `configuration.nix`, set `nixpkgs.hostPlatform = "x86_64-darwin";` (the comment right there tells you the same thing).

## Fresh-machine setup

On a brand new Mac, from a bare clone of this repo:

```sh
git clone https://github.com/HurricaneJames/dotfiles.git
cd dotfiles
```

Before you run it: open the config files and change the values listed in "Make it yours" below (username, home path, git identity, host label, and Intel vs Apple Silicon), and read the Homebrew cleanup warning.
`bootstrap.sh` applies the config to your machine, so do this first.

```sh
./bootstrap.sh
```

`bootstrap.sh` does three things, in order:

1. Installs Determinate Nix, if it isn't already installed.
2. Symlinks this repo to `~/.dotfiles`.
   This has to happen before the first build, because `home.nix` points at config files through `~/.dotfiles`.
3. Runs the first `darwin-rebuild switch`.
   It fetches the `darwin-rebuild` tool from the nix-darwin 26.05 release branch, then applies this repo's locked flake config.

After that, `darwin-rebuild` exists and you're on the normal workflow below.

### Validate without applying

Once Nix is installed (`bootstrap.sh` step 1 handles that), you can check that the config builds without touching your system - handy when you have edited something:

```sh
nix flake check --no-build
nix build .#darwinConfigurations.<HostName>.system --dry-run
```

Substitute `<HostName>` for one of the configuration names declared in
`flake.nix`'s `darwinConfigurations` block.

## Daily use

Edit the config files in place, then apply:

```sh
./rebuild.sh
```

That's it.
No separate build-and-copy step.

## Per-environment config

Each host in `flake.nix` is built by `mkHost`, which takes an optional path to an
environment-specific config file:

```nix
"Studio1" = mkHost null;                         # home profile (base config only)
"StudioB" = mkHost ./configuration-studiob.nix;  # work profile (base + extras)
```

The env file layers extras onto the shared base. Every field is optional (see
`configuration-studiob.nix` for the full schema):

- `homePackages` - extra Nix user packages (StudioB adds `go`)
- `casks` / `brews` - extra Homebrew casks and formulae
- `zshSessionVariables` - extra zsh env vars (non-secret; these get baked into
  the world-readable `/nix/store`)
- `zshInitContent` - shell-startup snippet appended to `.zshrc`

Hosts that don't need extras pass `null` and get the base config unchanged.

### GHE_API_TOKEN (secret handling)

The work profile exports `GHE_API_TOKEN` for GitHub Enterprise. The token is
**never** written into Nix - anything Nix reads at build time lands in the
world-readable `/nix/store`. Instead, `configuration-studiob.nix` generates a
`.zshrc` line that reads the token from the macOS login Keychain at shell
startup, so only the `security` command (not the token) is in the store.

One-time setup on the work machine:

```sh
security add-generic-password -a "$USER" -s GHE_API_TOKEN -w
```

That prompts for the token value and stores it in your login keychain. The
first shell that reads it may pop an "allow access" dialog - click **Always
Allow** and it stays silent afterward (the login keychain unlocks automatically
when you log into macOS, so new terminals don't re-prompt).

## Make it yours

This repo is mine.
If you clone it, change these before you run `bootstrap.sh`:

- **Username and home path** (`jburnett` / `/Users/jburnett`), in `configuration.nix`
  (the `system.primaryUser`, `users.users.<name>`, and `nix-homebrew.user`
  settings) and `home.nix` (`home.username` / `home.homeDirectory`).
- **Git identity** - this repo reads it from a gitignored, machine-local file
  rather than hardcoding it; `bootstrap.sh` prompts for your name and email and
  writes `.dotfiles-gituser.json`, which `flake.nix` reads at build time.
- **Host names** - the entries in `flake.nix`'s `darwinConfigurations` block
  (`Studio1`, `StudioB`). `bootstrap.sh --for <HostName>` picks which one a
  machine installs and saves it so `rebuild.sh` reuses it. Rename or add hosts
  to match your machines.
- **CPU architecture**, `hostPlatform` in `configuration.nix` (see Prerequisites above).

**Homebrew cleanup warning:** `configuration.nix` sets `homebrew.onActivation.cleanup = "zap"`.
That means every time you switch, Homebrew removes any package or cask on your machine that isn't listed in the `brews` and `casks` arrays in `configuration.nix`.
If you already have Homebrew stuff installed that isn't in that list, the first switch will uninstall it.
Read through `brews` and `casks` before you run `bootstrap.sh` or `rebuild.sh` for the first time, and add anything you want to keep.

**About `herdr`:** it's in the `brews` list.
It's a real public Homebrew formula (`brew info herdr` finds it in homebrew-core, no tap needed), so it will install fine.
If you don't use it, just remove it from `brews` in your copy.

**Heads-up:**

- `home/AGENTS.md` is my personal agent policy, and `home.nix` installs it for Claude, Codex, and opencode.
  If you clone this repo, you'd silently inherit my agent instructions - edit or delete `home/AGENTS.md` if you don't want that.
- The `cc` and `co` shell aliases in `home.nix` are high-agency shortcuts: `claude --dangerously-skip-permissions` and `codex --full-auto`.
  They're convenient for me, but know what they do before you use them.

## Repo tour

- `flake.nix` - the entry point.
  Wires up nixpkgs, nix-darwin, home-manager, and nix-homebrew, and declares each
  host in `darwinConfigurations` via `mkHost`.
- `configuration.nix` - system-level config: macOS defaults, Homebrew.
- `home.nix` - user-level config: shell, git, packages, and the symlinks described below.
- `<host>-configuration.nix` - optional per-environment extras layered onto the
  base (e.g. `configuration-studiob.nix`). See "Per-environment config" above.
- `bootstrap.sh` - one-time fresh-machine setup; `--for <HostName>` selects the config.
- `rebuild.sh` - re-applies the config after the first switch.
  Run this every time you make a change.
- `home/` - the actual config files that get symlinked into place (Neovim, WezTerm, herdr, Claude settings, the shared `AGENTS.md`).

## How the symlinks work

The files under `home/` are the real files - editing them here is editing your live config, no rebuild needed to see the change in your editor.
`home.nix` uses `mkOutOfStoreSymlink` to point paths like `~/.config/nvim` straight at `home/.config/nvim` in this repo, so the two never drift out of sync.
You only run `./rebuild.sh` when you change something that isn't just a symlinked file, like a package list or a system default.

## Notes

The first time you launch `nvim`, it bootstraps [lazy.nvim](https://github.com/folke/lazy.nvim) by cloning plugins from GitHub.
That needs network access once; after that it's offline.

## License

This repo is licensed under MIT No Attribution.
See `LICENSE`.
