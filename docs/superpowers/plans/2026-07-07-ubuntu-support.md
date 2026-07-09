# Ubuntu (x86_64 Linux) Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone-home-manager Linux build path so `bootstrap.sh`/`rebuild.sh` configure an Ubuntu 22.04 x86_64 machine the same way they configure a Mac, without disturbing the working nix-darwin path.

**Architecture:** Split `home.nix` into a shared `home-common.nix` plus thin `home-darwin.nix` / `home-linux.nix` wrappers. `flake.nix` gains a Linux-pinned nixpkgs input and a `homeConfigurations."linux-work"` output built by standalone home-manager. Homebrew-installed packages become Nix packages on Linux; `bootstrap.sh` sets zsh as the login shell (which home-manager cannot). A `configuration-ubuntu.nix` work env file layers on go/kubectl/ecr-helper, the anduril `NIX_PATH`, work Claude settings, and a file-sourced `GHE_API_TOKEN`.

**Tech Stack:** Nix flakes, home-manager (standalone + darwin module), nix-darwin (mac only), bash.

---

## Reference: source design

Full design at `docs/superpowers/specs/2026-07-07-ubuntu-support-design.md`. Read it if any task is ambiguous.

## Deviations recorded during execution

Two adjustments were made while implementing (both verified and kept):

1. **`herdr` from `nixpkgs-unstable` (Task 3).** `herdr` is not in the stable
   `nixos-26.05` channel, so `flake.nix` adds a `nixpkgs-unstable` input and a
   lazy overlay `(_: _: { herdr = unstable.herdr; })` on the Linux pkgs. The
   overlay touches only `herdr`; everything else stays on stable 26.05.
2. **`programs.home-manager.enable = true` in `home-linux.nix` (Task 6).**
   Standalone home-manager doesn't install the `home-manager` CLI unless this is
   set, and `rebuild.sh` needs it. `rebuild.sh`'s Linux branch also falls back to
   `nix run` when the CLI isn't yet on PATH (first-ever rebuild).

## Verification model

There is no unit-test framework here — the "tests" are Nix evaluation/build commands. The two invariants every task must preserve:

- **Mac stays green:** `nix eval --impure .#darwinConfigurations.Studio1.system.outPath` and `...StudioB...` still evaluate. (Requires `DOTFILES_GITUSER_FILE` set — see Task 0.)
- **Linux builds:** after Task 3, `nix build --impure .#homeConfigurations."linux-work".activationPackage` succeeds.

We cannot run `darwin-rebuild` here (no Mac), so the Mac checks are `nix eval` (evaluation only), which is sufficient to catch the refactor breaking the darwin path.

## File structure

- **Create** `home-common.nix` — shared home-manager config (moved out of `home.nix`).
- **Create** `home-darwin.nix` — mac wrapper (imports common; colima; mac compinit note).
- **Create** `home-linux.nix` — linux wrapper (imports common; herdr/wezterm/claude-code; own compinit).
- **Delete** `home.nix` — its content moves to `home-common.nix` + wrappers.
- **Create** `configuration-ubuntu.nix` — Linux work env file.
- **Modify** `flake.nix` — Linux nixpkgs/home-manager inputs, `mkLinuxHome`, `homeConfigurations`, darwin `home.nix` reference → `home-darwin.nix`.
- **Modify** `bootstrap.sh` — `uname` dispatch; Linux branch (home-manager build + chsh).
- **Modify** `rebuild.sh` — `uname` dispatch; Linux branch (`home-manager switch`).
- **Modify** `README.md` — Linux section, repo tour, macOS-only notes.

---

## Task 0: Preflight — establish the green baseline

**Files:** none (verification only).

- [ ] **Step 1: Ensure the git-identity file exists for impure eval**

The flake reads `DOTFILES_GITUSER_FILE`. If this box was never bootstrapped, create the file so evals work:

```bash
cd ~/dotfiles
test -f .dotfiles-gituser.json || printf '{ "name": "Jason Burnett", "email": "jburnett@example.com" }\n' > .dotfiles-gituser.json
export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
```

(Use your real work name/email if you intend to keep this file; it is gitignored.)

- [ ] **Step 2: Record the pre-change darwin baseline**

Run:
```bash
nix eval --impure .#darwinConfigurations.Studio1.system.outPath
nix eval --impure .#darwinConfigurations.StudioB.system.outPath
```
Expected: two `/nix/store/...-darwin-system-...` paths print, no error. Note them; they must still evaluate after the refactor (the hash may change once `home.nix` → `home-darwin.nix`, that's fine — it must not error).

---

## Task 1: Extract `home-common.nix` from `home.nix`

Pure refactor. `home.nix` becomes `home-common.nix` with a parametrized home directory and an `extraPackages` hook. The darwin path is rewired in Task 2; until then the flake still points at `home.nix`, so we keep `home.nix` in place until Task 2 to avoid a broken intermediate state.

**Files:**
- Create: `home-common.nix`

- [ ] **Step 1: Create `home-common.nix`**

Create `home-common.nix` with the full content below. It is today's `home.nix` with three changes: (a) new signature params `homeDirectory` + `extraPackages`, (b) `home.homeDirectory` uses the param, (c) package list drops `colima`, drops `herdr` (was never here — herdr is a brew), adds `++ extraPackages`, and `home.username`/`home.stateVersion` are removed (wrappers set them).

```nix
# Shared home-manager config for every platform. Thin wrappers
# (home-darwin.nix / home-linux.nix) import this and inject the platform
# differences via `homeDirectory` and `extraPackages`.
#
# `envFile` is an optional path to an environment-specific config (or null).
# When set it layers extra home packages, zsh session variables and zsh init
# content onto the shared base. See configuration-studiob.nix for the schema.
{ gitUser, envFile, homeDirectory, extraPackages ? [ ] }:

{ config, pkgs, lib, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  env = if envFile == null then { } else import envFile { inherit pkgs; };

  # Config files symlinked edit-in-place: the real file stays in my repo, the
  # target under $HOME just points at it. Keyed by target (relative to $HOME),
  # valued by source (relative to the dotfiles repo root). An environment can
  # replace a source - or add a brand-new file - via `env.configOverrides`
  # (see configuration-studiob.nix); the `//` lets its entries win.
  baseConfigFiles = {
    ".config/wezterm"            = "home/.config/wezterm";
    ".config/nvim"               = "home/.config/nvim";
    ".config/herdr"              = "home/.config/herdr";
    ".claude/settings.json"      = "home/.claude/settings.json";
    ".claude/CLAUDE.md"          = "home/AGENTS.md";
    ".codex/AGENTS.md"           = "home/AGENTS.md";
    ".config/opencode/AGENTS.md" = "home/AGENTS.md";
  };
  configFiles = baseConfigFiles // (env.configOverrides or { });
in

{
  home.homeDirectory = homeDirectory;
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    mosh
    # languages / runtimes
    python314
    # git tooling (git itself is installed via programs.git below)
    gh
    git-lfs
    # containers — docker-client is CLI + compose plugin + buildx + shell
    # completions. On macOS the daemon runs in colima (added by the darwin
    # wrapper); on Linux the daemon is native.
    docker-client
    docker-compose
    # the font everything renders in
    nerd-fonts.hack
  ] ++ extraPackages ++ (env.homePackages or [ ]);
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      setopt nomenucomplete
      setopt noautomenu
      bindkey '^f' autosuggest-accept
    '' + (env.zshInitContent or "");
    sessionVariables = {
      CLICOLOR = "1";
    } // (env.zshSessionVariables or { });
    shellAliases = {
      ".." = "cd ..";
      add = "git add .";
      push = "git push";
      pull = "git pull";
      m = "git switch main";
      cc = "claude --dangerously-skip-permissions";
      co = "codex --full-auto";
      k = "kubectl";
    };
  };

  programs.git.enable = true;
  programs.git.settings.user = gitUser;

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  home.file = builtins.mapAttrs
    (target: src: {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${src}";
    })
    configFiles;
}
```

Note: `enableCompletion` is intentionally NOT set here — each wrapper owns it (mac disables it because `/etc/zshrc` runs compinit; Linux disables the HM one and runs its own). The `env` import, `configFiles`/`mkOutOfStoreSymlink`, git, starship, and all aliases are byte-for-byte the same as today's `home.nix`.

- [ ] **Step 2: Verify it parses**

Run:
```bash
nix-instantiate --parse home-common.nix >/dev/null && echo PARSE_OK
```
Expected: `PARSE_OK` (no syntax errors). Full evaluation happens once a wrapper imports it (Task 2).

- [ ] **Step 3: Commit**

```bash
git add home-common.nix
git commit -m "refactor: extract shared home config into home-common.nix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `home-darwin.nix` and rewire the flake to it

Replace the flake's `home.nix` reference with `home-darwin.nix`, then delete `home.nix`. This keeps the Mac path behavior identical (colima + `enableCompletion=false`).

**Files:**
- Create: `home-darwin.nix`
- Modify: `flake.nix` (the `home-manager.users.jburnett = import ./home.nix ...` line)
- Delete: `home.nix`

- [ ] **Step 1: Create `home-darwin.nix`**

```nix
# macOS wrapper: imports the shared config and adds the mac-only bits.
# `herdr`/`wezterm`/`claude-code` come from Homebrew on mac (configuration.nix),
# not from Nix, so they are NOT added here.
{ gitUser, envFile }:

{ config, pkgs, ... }:

{
  imports = [ (import ./home-common.nix {
    inherit gitUser envFile;
    homeDirectory = "/Users/jburnett";
    extraPackages = with pkgs; [ colima ];  # mac-only rootless container VM
  }) ];

  home.username = "jburnett";
  home.stateVersion = "24.11";

  # nix-darwin's /etc/zshrc already runs compinit; don't run a 2nd (~3s).
  programs.zsh.enableCompletion = false;
}
```

- [ ] **Step 2: Point the flake's home-manager user at the darwin wrapper**

In `flake.nix`, change the line inside `mkHost`:
```nix
            home-manager.users.jburnett = import ./home.nix { inherit gitUser envFile; };
```
to:
```nix
            home-manager.users.jburnett = import ./home-darwin.nix { inherit gitUser envFile; };
```

- [ ] **Step 3: Delete the old `home.nix`**

```bash
git rm home.nix
```

- [ ] **Step 4: Verify the darwin path still evaluates (mac invariant)**

Run:
```bash
export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
nix eval --impure .#darwinConfigurations.Studio1.system.outPath
nix eval --impure .#darwinConfigurations.StudioB.system.outPath
```
Expected: both print a `/nix/store/...-darwin-system-...` path, no error. (This proves `home-common.nix` + `home-darwin.nix` evaluate correctly through the darwin module, exercising the full refactor.)

- [ ] **Step 5: Commit**

```bash
git add flake.nix home-darwin.nix
git commit -m "refactor: move mac home config into home-darwin.nix wrapper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add `home-linux.nix` and the flake Linux outputs

Add the Linux nixpkgs/home-manager inputs, `mkLinuxHome`, the `homeConfigurations."linux-work"` output, and the Linux wrapper. Uses a placeholder env of `null` first so we can verify the base build before adding the work env file (Task 4).

**Files:**
- Create: `home-linux.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Create `home-linux.nix`**

```nix
# Linux (standalone home-manager) wrapper: imports the shared config and adds
# the Linux-only bits. `herdr`/`wezterm`/`claude-code` come from Homebrew on
# mac; on Linux there is no Homebrew, so they install as Nix packages here.
{ gitUser, envFile }:

{ config, pkgs, lib, ... }:

{
  imports = [ (import ./home-common.nix {
    inherit gitUser envFile;
    homeDirectory = "/home/jburnett";
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
      if (( $#fresh )); then
        compinit -C -d $dump
      else
        compinit -d $dump
        touch $dump
      fi
    }
  '';
}
```

- [ ] **Step 2: Add the Linux inputs to `flake.nix`**

In the `inputs` block, after the existing `home-manager` input, add:
```nix
    # Linux uses the NixOS channel (the -darwin channel above is macOS-cached),
    # with its own home-manager instance following it.
    nixpkgs-linux.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager-linux.url = "github:nix-community/home-manager/release-26.05";
    home-manager-linux.inputs.nixpkgs.follows = "nixpkgs-linux";
```

- [ ] **Step 3: Thread the new inputs into the outputs function**

Change the outputs signature:
```nix
  outputs = inputs@{ self, nix-darwin, nix-homebrew, home-manager, nixpkgs }:
```
to:
```nix
  outputs = inputs@{ self, nix-darwin, nix-homebrew, home-manager, nixpkgs
                   , nixpkgs-linux, home-manager-linux }:
```

- [ ] **Step 4: Add `mkLinuxHome` and the `homeConfigurations` output**

In the `let ... in` body, after the `mkHost` definition, add:
```nix
      # Build a standalone home-manager configuration for Linux. No nix-darwin
      # layer, so allowUnfree (claude-code) is set on the pkgs import here.
      mkLinuxHome = envFile: home-manager-linux.lib.homeManagerConfiguration {
        pkgs = import nixpkgs-linux {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        modules = [ (import ./home-linux.nix { inherit gitUser envFile; }) ];
      };
```

Then in the returned attrset, after the `darwinConfigurations = { ... };` block, add:
```nix
      homeConfigurations = {
        # One fixed entry serves any Linux box (hostname-independent).
        "linux-work" = mkLinuxHome ./configuration-ubuntu.nix;
      };
```

- [ ] **Step 5: Create a temporary stub `configuration-ubuntu.nix`**

Task 4 writes the real file, but the flake now references it, so create a minimal stub so this task's build works:
```nix
{ pkgs, ... }:
{ }
```

- [ ] **Step 6: Verify the Linux config builds (Linux invariant)**

Run:
```bash
export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
nix build --impure .#homeConfigurations."linux-work".activationPackage --no-link --print-out-paths
```
Expected: a `/nix/store/...-home-manager-generation` path prints, no error. (Fetches the Linux nixpkgs on first run — may take a while.)

- [ ] **Step 7: Verify the darwin path STILL evaluates (mac invariant)**

Run:
```bash
nix eval --impure .#darwinConfigurations.Studio1.system.outPath
```
Expected: prints a path, no error.

- [ ] **Step 8: Commit**

```bash
git add flake.nix flake.lock home-linux.nix configuration-ubuntu.nix
git commit -m "feat: add standalone home-manager Linux build path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Write the real `configuration-ubuntu.nix` work env file

Replace the stub with the full work env (go/kubectl/ecr-helper, anduril NIX_PATH, work Claude settings, file-sourced GHE_API_TOKEN).

**Files:**
- Modify: `configuration-ubuntu.nix`

- [ ] **Step 1: Replace `configuration-ubuntu.nix` with the full file**

```nix
# Environment-specific config for the Ubuntu work machine.
#
# flake.nix wires this in via `mkLinuxHome ./configuration-ubuntu.nix`.
# Every field below is optional - home-common.nix reads them with
# `env.<field> or <default>`, so you can drop any you don't need.
{ pkgs, ... }:

{
  # Extra home-manager packages (appended to home-common.nix's home.packages).
  homePackages = with pkgs; [
    go                            # golang for work
    kubectl
    amazon-ecr-credential-helper  # docker-credential-ecr-login for AWS ECR
  ];

  # No casks/brews on Linux - there is no Homebrew layer. Those fields are
  # simply omitted (home-common.nix never reads them; only configuration.nix on
  # mac does).

  # Override the source of specific home.file config symlinks for this env.
  # Work needs its own Claude settings (same file StudioB uses).
  configOverrides = {
    ".claude/settings.json" = "home/.claude/settings.studiob.json";
  };

  # Extra zsh session variables (merged into home-common.nix's sessionVariables).
  zshSessionVariables = {
    NIX_PATH = "/home/jburnett/sources/anduril-nixpkgs";
  };

  # Appended to home-common.nix's zsh initContent, run at every shell startup.
  #
  # There is no macOS Keychain on Linux, so GHE_API_TOKEN is read from a
  # gitignored file rather than a keychain. The token never lands in the
  # world-readable /nix/store (Nix only bakes in the `cat` line, not its
  # output). One-time setup on this machine:
  #
  #     mkdir -p ~/.config/dotfiles
  #     printf '%s' "<token>" > ~/.config/dotfiles/ghe-token
  #     chmod 600 ~/.config/dotfiles/ghe-token
  zshInitContent = ''
    [ -r "$HOME/.config/dotfiles/ghe-token" ] && \
      export GHE_API_TOKEN="$(cat "$HOME/.config/dotfiles/ghe-token")"
  '';
}
```

- [ ] **Step 2: Verify the Linux build picks up the work env**

Run:
```bash
export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
nix build --impure .#homeConfigurations."linux-work".activationPackage --no-link --print-out-paths
```
Expected: builds, prints a store path. To spot-check the env was applied, confirm `go` is in the closure:
```bash
OUT=$(nix build --impure .#homeConfigurations."linux-work".activationPackage --no-link --print-out-paths)
grep -rl "GHE_API_TOKEN" "$OUT/home-files/.zshrc" && echo TOKEN_LINE_PRESENT
```
Expected: `TOKEN_LINE_PRESENT` (the generated `.zshrc` contains the token-reading line).

- [ ] **Step 3: Commit**

```bash
git add configuration-ubuntu.nix
git commit -m "feat: add Ubuntu work env file (go/kubectl/ecr, GHE token, anduril NIX_PATH)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: OS dispatch in `bootstrap.sh`

Add a `uname -s` branch. Shared code (git identity, `~/.dotfiles` symlink, profile file) stays; the build step and shell setup branch by OS.

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Add an OS variable near the top**

After the `GITUSER_FILE=` line (around line 10), add:
```bash
OS="$(uname -s)"   # Darwin or Linux
```

- [ ] **Step 2: Make the default CONFIG OS-aware**

The mac default is `CONFIG="Studio1"`. Change it so Linux defaults to the fixed Linux key. Replace:
```bash
CONFIG="Studio1"
```
with:
```bash
if [ "$OS" = "Linux" ]; then
  CONFIG="linux-work"
else
  CONFIG="Studio1"
fi
```

- [ ] **Step 3: Branch the eval-check + build steps by OS**

The current script (Step "Step 3: first darwin-rebuild switch" through the end) is mac-specific. Wrap the existing mac logic and add a Linux branch. Replace everything from the `# Fail early if the requested configuration doesn't exist` comment block down to the final `echo "==> Done...` with:

```bash
export DOTFILES_GITUSER_FILE="$GITUSER_FILE"

if [ "$OS" = "Linux" ]; then
  # --- Linux: standalone home-manager ---------------------------------------
  # Validate the requested homeConfiguration exists before building.
  if ! nix eval --impure --raw \
      "$DIR#homeConfigurations.\"$CONFIG\".activationPackage.outPath" >/dev/null 2>&1; then
    echo "error: '$CONFIG' is not a homeConfiguration in flake.nix." >&2
    nix eval --impure --apply builtins.attrNames "$DIR#homeConfigurations" --json 2>/dev/null \
      | tr -d '[]"' | tr ',' '\n' | sed 's/^/         - /' >&2
    exit 1
  fi
  printf '%s\n' "$CONFIG" > "$PROFILE_FILE"
  echo "==> Using flake configuration: $CONFIG (saved to $PROFILE_FILE)"

  echo "==> Step 3: first home-manager switch"
  # home-manager isn't on PATH yet on a fresh box, so run it from the flake once.
  # --impure lets the flake read the gitignored git identity file.
  nix run github:nix-community/home-manager/release-26.05 -- \
    switch --impure --flake "$DIR#$CONFIG"

  echo "==> Step 4: make the Nix zsh your login shell"
  # home-manager cannot set the login shell; do it here (idempotent).
  ZSH_PATH="$HOME/.nix-profile/bin/zsh"
  if [ -x "$ZSH_PATH" ]; then
    grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
    if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_PATH" ]; then
      chsh -s "$ZSH_PATH"
      echo "    login shell set to $ZSH_PATH (log out/in for it to take effect)"
    else
      echo "    login shell already $ZSH_PATH"
    fi
  else
    echo "    warning: $ZSH_PATH not found; skipping chsh" >&2
  fi

  echo "==> Done. Use ./rebuild.sh for future changes."
  exit 0
fi

# --- macOS: nix-darwin (unchanged below) ------------------------------------
# Fail early if the requested configuration doesn't exist in the flake, before
# we hand it to darwin-rebuild (which would otherwise fail more cryptically).
# --impure so the flake can read the (gitignored) git identity file.
if ! nix eval --impure --raw "$DIR#darwinConfigurations.$CONFIG.system.outPath" >/dev/null 2>&1; then
  echo "error: '$CONFIG' is not a darwinConfiguration in flake.nix." >&2
  echo "       available configurations:" >&2
  nix eval --impure --apply builtins.attrNames "$DIR#darwinConfigurations" --json 2>/dev/null \
    | tr -d '[]"' | tr ',' '\n' | sed 's/^/         - /' >&2
  exit 1
fi

# Save the choice so rebuild.sh applies the same configuration later.
printf '%s\n' "$CONFIG" > "$PROFILE_FILE"
echo "==> Using flake configuration: $CONFIG (saved to $PROFILE_FILE)"

echo "==> Step 3: first darwin-rebuild switch (pinned to nix-darwin-26.05)"
NIX_ENV="/nix/var/nix/profiles/default/bin/nix-env"
[ -e "$NIX_ENV" ] || NIX_ENV="$(command -v nix-env || true)"
if [ -n "$NIX_ENV" ] && [ "$(readlink /usr/local/bin/nix-env 2>/dev/null)" != "$NIX_ENV" ]; then
  sudo mkdir -p /usr/local/bin
  sudo ln -sfn "$NIX_ENV" /usr/local/bin/nix-env
fi

NIX_BIN="$(command -v nix)"
sudo DOTFILES_GITUSER_FILE="$GITUSER_FILE" \
  "$NIX_BIN" run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
  switch --impure --flake "$DIR#$CONFIG"

echo "==> Done. Use ./rebuild.sh for future changes."
```

Note: the existing `--for` arg parsing and the big explanatory comments above the mac build block stay as-is; only the eval-check-through-Done section is what this step restructures. Keep the mac comment blocks (secure_path / nix-env explanation) intact — they're moved verbatim into the macOS branch above (trimmed here for brevity; preserve the originals from the current file).

- [ ] **Step 3: Lint the script**

Run:
```bash
bash -n bootstrap.sh && echo SYNTAX_OK
command -v shellcheck >/dev/null && shellcheck bootstrap.sh || echo "(shellcheck not installed, skipping)"
```
Expected: `SYNTAX_OK`. If shellcheck runs, no new errors vs. the mac original (pre-existing SC1091 disables are fine).

- [ ] **Step 4: Dry-run the Linux branch logic (no system changes)**

Verify the eval-check path works without actually switching:
```bash
export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
nix eval --impure --raw '.#homeConfigurations."linux-work".activationPackage.outPath' && echo EVAL_OK
```
Expected: a store path then `EVAL_OK` — confirming the validation command the script uses succeeds.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: OS-dispatch bootstrap.sh; Linux runs home-manager + sets zsh login shell

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: OS dispatch in `rebuild.sh`

Linux branch is a plain `home-manager switch`; the mac branch is the existing logic untouched.

**Files:**
- Modify: `rebuild.sh`

- [ ] **Step 1: Add an OS variable near the top**

After the `GITUSER_FILE=` line, add:
```bash
OS="$(uname -s)"   # Darwin or Linux
```

- [ ] **Step 2: Make the config-name defaulting OS-aware**

The `config_exists()` helper currently checks `darwinConfigurations`. Add a Linux-aware variant. Replace the `config_exists()` function:
```bash
config_exists() {
  nix eval --impure --raw "$DIR#darwinConfigurations.$1.system.outPath" >/dev/null 2>&1
}
```
with:
```bash
config_exists() {
  if [ "$OS" = "Linux" ]; then
    nix eval --impure --raw "$DIR#homeConfigurations.\"$1\".activationPackage.outPath" >/dev/null 2>&1
  else
    nix eval --impure --raw "$DIR#darwinConfigurations.$1.system.outPath" >/dev/null 2>&1
  fi
}
```

- [ ] **Step 3: Make the fallback default + the enumerate list OS-aware**

In the block that picks a config when none is saved, the enumerate command lists `darwinConfigurations`. Replace the `select`-menu block's enumeration source. Find:
```bash
  done < <(
    nix eval --impure --apply builtins.attrNames "$DIR#darwinConfigurations" --json 2>/dev/null \
      | tr -d '[]"' | tr ',' '\n'
  )
```
with:
```bash
  done < <(
    if [ "$OS" = "Linux" ]; then
      nix eval --impure --apply builtins.attrNames "$DIR#homeConfigurations" --json 2>/dev/null
    else
      nix eval --impure --apply builtins.attrNames "$DIR#darwinConfigurations" --json 2>/dev/null
    fi | tr -d '[]"' | tr ',' '\n'
  )
```

- [ ] **Step 4: Branch the final switch command**

Replace the mac-specific tail (from the `ensure_nix_on_secure_path` call through the final `exec sudo ... darwin-rebuild ...`) with:
```bash
export DOTFILES_GITUSER_FILE="$GITUSER_FILE"

if [ "$OS" = "Linux" ]; then
  # Standalone home-manager: no sudo, no secure_path dance, no darwin-rebuild.
  # --impure so the flake can read the gitignored identity file.
  exec home-manager switch --impure --flake "$DIR#$CONFIG"
fi

# --- macOS: nix-darwin (unchanged) ------------------------------------------
# Make nix-env reachable from the home-manager activation step (see the helper).
ensure_nix_on_secure_path

# Resolve darwin-rebuild to an absolute path (see the long comment above).
DARWIN_REBUILD="$(command -v darwin-rebuild)"

# --impure + inline VAR=val so the flake can read the gitignored identity file
# even though sudo resets the environment.
exec sudo DOTFILES_GITUSER_FILE="$GITUSER_FILE" \
  "$DARWIN_REBUILD" switch --impure --flake "$DIR#$CONFIG"
```

Keep the `ensure_nix_on_secure_path` function definition and its big explanatory comment where they are (near the top); only its invocation moves into the mac branch. The existing `export DOTFILES_GITUSER_FILE` line near the top can stay (harmless duplicate) or be removed — leave it to minimize diff.

- [ ] **Step 5: Lint the script**

Run:
```bash
bash -n rebuild.sh && echo SYNTAX_OK
command -v shellcheck >/dev/null && shellcheck rebuild.sh || echo "(shellcheck not installed, skipping)"
```
Expected: `SYNTAX_OK`.

- [ ] **Step 6: End-to-end apply on this Ubuntu box**

This is the real integration test. Run:
```bash
./rebuild.sh
```
Expected: `home-manager` builds and activates a generation, no error. Then verify:
```bash
test -L ~/.config/nvim && echo NVIM_SYMLINK_OK
test -x ~/.nix-profile/bin/zsh && echo ZSH_INSTALLED_OK
~/.nix-profile/bin/zsh -ic 'echo $CLICOLOR; alias k; whence starship' 2>&1 | tail -3
```
Expected: `NVIM_SYMLINK_OK`, `ZSH_INSTALLED_OK`, `CLICOLOR=1`, the `k=kubectl` alias, and a starship path — proving the shared zsh config, aliases, and starship all activated.

- [ ] **Step 7: Commit**

```bash
git add rebuild.sh
git commit -m "feat: OS-dispatch rebuild.sh; Linux runs home-manager switch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Set zsh as login shell + verify the full bootstrap path

Task 5 added the chsh logic to `bootstrap.sh`, but a machine that already had Nix (like this one) may have skipped it. Run the shell setup and verify it end-to-end.

**Files:** none (verification + one-time system action).

- [ ] **Step 1: Register the Nix zsh and set it as the login shell**

Run:
```bash
ZSH_PATH="$HOME/.nix-profile/bin/zsh"
grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
[ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_PATH" ] && chsh -s "$ZSH_PATH" || echo "already set"
```
Expected: no error; `chsh` may prompt for your password.

- [ ] **Step 2: Verify the login shell changed**

Run:
```bash
getent passwd "$USER" | cut -d: -f7
grep -c "$HOME/.nix-profile/bin/zsh" /etc/shells
```
Expected: the path printed is `/home/jburnett/.nix-profile/bin/zsh`, and the grep count is `1`.

- [ ] **Step 3: Verify a fresh login shell loads the config**

Open a NEW terminal (or `su - $USER`) and run inside it:
```bash
echo "$0"                 # should be zsh
echo "$CLICOLOR"          # 1
alias k                   # k=kubectl
```
Expected: zsh, `1`, `k=kubectl`. Completion works (press Tab). No compinit-related lag on second launch (the `-C` fast path).

- [ ] **Step 4: (If GHE token needed) set up the token file**

Run:
```bash
mkdir -p ~/.config/dotfiles
printf '%s' "<your-ghe-token>" > ~/.config/dotfiles/ghe-token
chmod 600 ~/.config/dotfiles/ghe-token
```
Then in a new shell: `echo "${GHE_API_TOKEN:+SET}"` → expected `SET`. (Skip if you don't need GHE access on this box yet.)

No commit (system state only).

---

## Task 8: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a Linux setup subsection**

After the macOS "Fresh-machine setup" section (before "## Daily use"), add:

````markdown
### Linux (Ubuntu x86_64)

This repo also configures an Ubuntu 22.04 x86_64 machine, using standalone
home-manager instead of nix-darwin (there is no `system.defaults` layer on
Linux, and packages come from Nix rather than Homebrew).

```sh
git clone <this repo> ~/dotfiles && cd ~/dotfiles
./bootstrap.sh
```

`bootstrap.sh` on Linux:

1. Installs Determinate Nix if it isn't already present.
2. Symlinks the repo to `~/.dotfiles`.
3. Runs the first `home-manager switch` for `linux-work`.
4. Registers the Nix zsh in `/etc/shells` and `chsh`es your login shell to it.
   Log out and back in for the new shell to take effect.

Daily use is the same `./rebuild.sh` as on mac.

**GHE_API_TOKEN on Linux:** there's no macOS Keychain, so the token is read
from a gitignored file at shell startup. One-time setup:

```sh
mkdir -p ~/.config/dotfiles
printf '%s' "<token>" > ~/.config/dotfiles/ghe-token
chmod 600 ~/.config/dotfiles/ghe-token
```

macOS-only features (`system.defaults`, Homebrew casks/brews, `colima`) do not
apply on Linux; the Docker daemon runs natively there.
````

- [ ] **Step 2: Add the new files to the repo tour**

In the "## Repo tour" section, add these entries:
```markdown
- `home-common.nix` - shared home-manager config (zsh, git, packages, symlinks).
- `home-darwin.nix` / `home-linux.nix` - thin per-platform wrappers around
  `home-common.nix`; each adds only the platform's differences.
- `configuration-ubuntu.nix` - Linux work env file (analogous to
  `configuration-studiob.nix`), layered onto the base via `mkLinuxHome`.
```
And update the existing `home.nix` bullet: replace it with a note that the old
`home.nix` was split into `home-common.nix` + the two wrappers.

- [ ] **Step 3: Verify markdown renders / no broken references**

Run:
```bash
grep -n "home.nix" README.md
```
Expected: no stale reference implying `home.nix` still exists as the entry point (the split is described instead).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document Ubuntu (Linux) setup and the home.nix split

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (all invariants)

- [ ] **Mac path evaluates:**
  ```bash
  export DOTFILES_GITUSER_FILE="$PWD/.dotfiles-gituser.json"
  nix eval --impure .#darwinConfigurations.Studio1.system.outPath
  nix eval --impure .#darwinConfigurations.StudioB.system.outPath
  ```
  Both print a path, no error.

- [ ] **Linux path builds:**
  ```bash
  nix build --impure .#homeConfigurations."linux-work".activationPackage --no-link --print-out-paths
  ```
  Prints a store path.

- [ ] **`nix flake check` (evaluation of all outputs):**
  ```bash
  nix flake check --impure --no-build
  ```
  No error. (`--impure` because the flake reads the gitignored identity file.)

- [ ] **Live on Ubuntu:** `./rebuild.sh` activates cleanly; new zsh login shell has aliases, starship, completion; symlinks in place.

## Self-review notes

- Every spec section maps to a task: flake changes (T3), home-common (T1),
  home-darwin (T2), home-linux (T3), configuration-ubuntu (T4), bootstrap (T5),
  rebuild (T6), zsh login shell (T5/T7), README/docs (T8).
- Type/name consistency: the config key `"linux-work"` and the attr path
  `homeConfigurations."<key>".activationPackage` are used identically in the
  flake (T3), bootstrap (T5), rebuild (T6), and every verification block.
- `home-common.nix` signature `{ gitUser, envFile, homeDirectory, extraPackages ? [] }`
  matches both wrappers' `import ./home-common.nix { ... }` call sites (T2, T3).
