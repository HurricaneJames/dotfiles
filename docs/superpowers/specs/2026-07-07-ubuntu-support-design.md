# Ubuntu (x86_64 Linux) support

## Problem

The repo configures a macOS dev machine from one `bootstrap.sh` (once) plus
`rebuild.sh` (every change), built on nix-darwin + nix-homebrew +
home-manager-as-a-module. We want the same one-command experience on an Ubuntu
22.04 x86_64 machine.

Linux has no nix-darwin (`system.defaults` are macOS-only) and no Homebrew in
this design. Standalone home-manager also cannot set a login shell. So Linux
needs: a standalone home-manager build path, Nix-native replacements for what
Homebrew installed, and shell-setup handled by the bootstrap script.

## Decisions (from brainstorming)

- **macOS stays on nix-darwin.** Linux gets a new standalone-Nix path. Two build
  mechanisms; the working Mac path is behaviorally unchanged.
- **No Homebrew on Linux.** What Homebrew installed on mac (`herdr`, `wezterm`,
  `claude-code`) becomes regular Nix `home.packages` on Linux. `wezterm` and
  `claude-code` are in the stable `nixos-26.05` channel; `herdr` is **not** in
  stable, so it is overlaid from `nixos-unstable` (see flake.nix section).
- **zsh is installed via Nix, is the same fast-compinit config as mac, and is
  the default login shell.** `bootstrap.sh` registers it in `/etc/shells` and
  runs `chsh` (home-manager cannot).
- **Structure: split `home.nix` into `home-common.nix` + thin
  `home-darwin.nix` / `home-linux.nix` wrappers** (brainstorming Approach 2).
- **This is a work machine.** Add a Linux work env file
  (`configuration-ubuntu.nix`) carrying go/kubectl/amazon-ecr-credential-helper,
  the anduril `NIX_PATH`, work Claude settings, and `GHE_API_TOKEN`.
- **`GHE_API_TOKEN` comes from a gitignored file** (`~/.config/dotfiles/ghe-token`,
  mode 600) sourced at shell startup — there is no macOS Keychain on Linux.
- **The Linux homeConfiguration is keyed by a fixed name** `jburnett@linux`
  (hostname-independent); one entry serves any Linux box.

## Architecture

```
                    bootstrap.sh / rebuild.sh
                    (shared: git identity, ~/.dotfiles symlink, profile file)
                                  |
                 uname -s ────────┴────────
                /                          \
          Darwin                          Linux
   darwin-rebuild switch          home-manager switch
   .#darwinConfigurations.<H>     .#homeConfigurations."jburnett@linux"
          |                                  |
   configuration.nix                  (no system layer)
   (system.defaults, homebrew)              |
          |                                  |
   home-darwin.nix                    home-linux.nix
          \                                  /
                     home-common.nix
        (zsh, git, starship, packages, symlinks — shared)
```

`home-common.nix` is the single source of truth for everything shared. The two
wrappers inject only the platform differences.

## Design

### flake.nix

Add a Linux-pinned nixpkgs + home-manager (the current inputs track the
`-darwin` channel, which is macOS-cached; NixOS channel gives Linux better
binary-cache hits):

```nix
nixpkgs-linux.url = "github:NixOS/nixpkgs/nixos-26.05";
home-manager-linux.url = "github:nix-community/home-manager/release-26.05";
home-manager-linux.inputs.nixpkgs.follows = "nixpkgs-linux";
# herdr isn't in stable 26.05; overlay it from unstable (intentionally unpinned).
nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
```

Add a `mkLinuxHome` helper parallel to `mkHost`, reading the same gitignored
`gitUser` file:

```nix
mkLinuxHome = envFile:
  let
    unstable = import nixpkgs-unstable {
      system = "x86_64-linux";
      config.allowUnfree = true;
    };
  in
  home-manager-linux.lib.homeManagerConfiguration {
    pkgs = import nixpkgs-linux {
      system = "x86_64-linux";
      config.allowUnfree = true;   # claude-code is unfree; no nix-darwin layer to set this
      overlays = [ (_: _: { herdr = unstable.herdr; }) ];  # herdr only in unstable
    };
    modules = [ (import ./home-linux.nix { inherit gitUser envFile; }) ];
  };
```

Add the output alongside the untouched `darwinConfigurations`:

```nix
homeConfigurations = {
  "jburnett@linux" = mkLinuxHome ./configuration-ubuntu.nix;
};
```

The darwin block, `mkHost`, and the `gitUser` handling are unchanged.

### home-common.nix (shared core, from today's home.nix)

Signature gains `homeDirectory` and an `extraPackages` hook so wrappers inject
platform differences:

```nix
{ gitUser, envFile, homeDirectory, extraPackages ? [ ] }:
{ config, pkgs, lib, ... }:
```

Unchanged from today's home.nix: the whole `programs.zsh` block
(autosuggestion, syntaxHighlighting, `initContent` `setopt`/`bindkey`,
`sessionVariables`, all `shellAliases`), `programs.git`, `programs.starship`,
`fonts.fontconfig.enable`, `home.sessionVariables.EDITOR`, the `env` import, and
the entire `configFiles` (`baseConfigFiles // (env.configOverrides or {})`) +
`mkOutOfStoreSymlink` mechanism.

Changed here:

- `home.homeDirectory = homeDirectory;` (was hardcoded `/Users/jburnett`). The
  `dotfiles` path still derives from `config.home.homeDirectory`, so it follows.
- Shared package list drops `colima` (macOS-only container VM) and does **not**
  include `herdr` (mac gets it via Homebrew, Linux via its wrapper). Shared list:
  `ripgrep fd fzf jq lazygit neovim mosh python314 gh git-lfs docker-client
  docker-compose nerd-fonts.hack`, then `++ extraPackages ++ (env.homePackages or [])`.
- `home.username` and `home.stateVersion` move to the wrappers (mechanical; keeps
  common free of per-host identity). `home.stateVersion = "24.11"` on both.
- `programs.zsh.enableCompletion` is **not set here** — each wrapper owns it
  (see below), because the compinit strategy differs by platform.

### home-darwin.nix (thin wrapper — preserves today's mac behavior)

```nix
{ gitUser, envFile }:
{ config, pkgs, ... }:
{
  imports = [ (import ./home-common.nix {
    inherit gitUser envFile;
    homeDirectory = "/Users/jburnett";
    extraPackages = with pkgs; [ colima ];   # mac-only container VM
  }) ];
  home.username = "jburnett";
  home.stateVersion = "24.11";
  # nix-darwin's /etc/zshrc already runs compinit; don't run a 2nd (~3s).
  programs.zsh.enableCompletion = false;
}
```

`herdr` / `wezterm` / `claude-code` keep coming from Homebrew on mac
(`configuration.nix` unchanged). Net mac behavior: identical to today.

### home-linux.nix (thin wrapper — standalone, owns its own compinit)

```nix
{ gitUser, envFile }:
{ config, pkgs, lib, ... }:
{
  imports = [ (import ./home-common.nix {
    inherit gitUser envFile;
    homeDirectory = "/home/jburnett";
    # herdr/wezterm/claude-code come from Homebrew on mac; from Nix here.
    extraPackages = with pkgs; [ herdr wezterm claude-code ];
  }) ];
  home.username = "jburnett";
  home.stateVersion = "24.11";

  # No nix-darwin /etc/zshrc here, so home-manager must run compinit itself.
  # Reuse the same fast-path logic configuration.nix uses on mac (-C when the
  # dump is <24h old, else full rebuild+touch). Prepend it to the shared
  # initContent via lib.mkBefore so common's setopt/bindkey still run after.
  programs.zsh.enableCompletion = false;
  programs.zsh.initContent = lib.mkBefore ''
    autoload -Uz compinit
    () {
      local dump=''${ZDOTDIR:-$HOME}/.zcompdump
      local -a fresh=($dump(Nmh-24))
      if (( $#fresh )); then compinit -C -d $dump
      else compinit -d $dump; touch $dump; fi
    }
  '';
}
```

`programs.zsh.initContent` is a merged option in home-manager; `lib.mkBefore`
guarantees compinit runs before the shared `setopt`/`bindkey`.

### configuration-ubuntu.nix (Linux work env file)

Same schema as `configuration-studiob.nix`, adapted for Linux. Every field is
optional; `home-common.nix` reads them via `env.<field> or <default>`.

```nix
{ pkgs, ... }:
{
  homePackages = with pkgs; [
    go
    kubectl
    amazon-ecr-credential-helper   # docker-credential-ecr-login for AWS ECR
  ];

  # No casks/brews — Linux has no Homebrew layer. Fields omitted.

  # Work needs its own Claude settings (same override StudioB uses).
  configOverrides = {
    ".claude/settings.json" = "home/.claude/settings.studiob.json";
  };

  zshSessionVariables = {
    NIX_PATH = "/home/jburnett/sources/anduril-nixpkgs";
  };

  # GHE_API_TOKEN from a gitignored file (no macOS Keychain on Linux).
  # One-time setup:
  #   mkdir -p ~/.config/dotfiles
  #   printf '%s' "<token>" > ~/.config/dotfiles/ghe-token
  #   chmod 600 ~/.config/dotfiles/ghe-token
  zshInitContent = ''
    [ -r "$HOME/.config/dotfiles/ghe-token" ] && \
      export GHE_API_TOKEN="$(cat "$HOME/.config/dotfiles/ghe-token")"
  '';
}
```

The token file lives under `$HOME`, not the repo, so it can never be committed;
no `.gitignore` change is needed for it.

### bootstrap.sh (OS dispatch)

Branch on `uname -s` (`Darwin` vs `Linux`). Shared, unchanged: git-identity
prompt, `~/.dotfiles` symlink, profile-file save/validate.

Linux branch:

1. Nix install: the Determinate installer works on Linux; the existing
   `command -v nix` skip covers already-installed boxes.
2. First build straight from the flake (parallel to mac's darwin-rebuild dance):
   ```sh
   nix run github:nix-community/home-manager/release-26.05 -- \
     switch --impure --flake "$DIR#$CONFIG"
   ```
   `--impure` so the flake reads the gitignored `gitUser` file. After this,
   `home-manager` is on PATH for `rebuild.sh`.
3. zsh as default login shell (home-manager cannot do this), after the build so
   the Nix zsh exists:
   ```sh
   ZSH_PATH="$HOME/.nix-profile/bin/zsh"
   grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells
   [ "$(getent passwd "$USER" | cut -d: -f7)" = "$ZSH_PATH" ] || chsh -s "$ZSH_PATH"
   ```
   Idempotent. None of mac's `/usr/local/bin/nix-env` secure_path workarounds
   apply on Linux.

Config selection: Linux defaults `CONFIG` to `jburnett@linux` and validates it
via `nix eval --impure .#homeConfigurations."jburnett@linux".activationPackage`
(parallel to the darwin `config_exists` check). `--for` is not needed on Linux
(single fixed config), but the shared profile-file machinery still works.

### rebuild.sh (OS dispatch)

Linux branch is much simpler than mac (no sudo, no secure_path symlink, no
darwin-rebuild resolution):

```sh
export DOTFILES_GITUSER_FILE="$GITUSER_FILE"
exec home-manager switch --impure --flake "$DIR#$CONFIG"
```

The git-identity-file existence check and `~/.dotfiles` symlink stay shared.

### README.md & docs

- Add a "Linux (Ubuntu)" setup subsection: the `home-manager switch` workflow,
  the automatic `chsh`/`/etc/shells` step, and the one-time
  `~/.config/dotfiles/ghe-token` secret setup.
- Add `configuration-ubuntu.nix` to the repo tour.
- Note that `system.defaults`, Homebrew, and `colima` are macOS-only.
- `.gitignore` already covers `.dotfiles-gituser.json` / `.dotfiles-profile`; no
  change needed.
- AGENTS.md unchanged (the zap-cleanup note is macOS-Homebrew-specific).

## Verification

- `nix flake check --no-build` passes.
- `nix build .#homeConfigurations."jburnett@linux".activationPackage` builds.
- Existing darwin outputs still evaluate:
  `nix eval .#darwinConfigurations.Studio1.system.outPath` (and StudioB).
- On the Ubuntu box: `./bootstrap.sh` completes; a new login shell is the Nix
  zsh (`echo $SHELL` / `getent passwd $USER`), completion works, aliases +
  starship present, symlinks in place, `GHE_API_TOKEN` set when the token file
  exists.
- `./rebuild.sh` re-applies cleanly.

## Out of scope

- NixOS (this targets Ubuntu with standalone home-manager, not a NixOS system).
- Homebrew/Linuxbrew on Linux.
- Porting macOS `system.defaults` to Linux desktop settings.
- Keyring/`pass`-based secret handling (chose gitignored file).
- aarch64-linux (this machine is x86_64).
```