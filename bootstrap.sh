#!/usr/bin/env bash
# Bootstraps a new machine from nothing to a built config: nix-darwin on macOS,
# standalone home-manager on Linux (branched on `uname` below).
# Run this once. After it finishes, use ./rebuild.sh for every later change.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_FILE="$DIR/.dotfiles-profile"
# Absolute path (works for any user, wherever their home lives) to the
# machine-local git identity. flake.nix reads it via DOTFILES_GITUSER_FILE.
GITUSER_FILE="$DIR/.dotfiles-gituser.json"
OS="$(uname -s)"   # Darwin or Linux

# Which flake configuration (darwinConfigurations.<name>) to install.
# Home profile is the default; pass --for StudioB for the work machine.
if [ "$OS" = "Linux" ]; then
  CONFIG="jburnett@linux"
else
  CONFIG="Studio1"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --for)
      [ $# -ge 2 ] || { echo "error: --for needs a configuration name" >&2; exit 1; }
      CONFIG="$2"; shift 2 ;;
    --for=*)
      CONFIG="${1#--for=}"; shift ;;
    *)
      echo "usage: $0 [--for <configurationName>]" >&2; exit 1 ;;
  esac
done

# Prompt for the git identity and write it as JSON for flake.nix to read.
# Kept out of the repo (gitignored) so a work email never lands in git.
if [ ! -f "$GITUSER_FILE" ]; then
  echo "==> Git identity for this machine (used by git and read by flake.nix)"
  read -r -p "    git user.name:  " GIT_NAME
  read -r -p "    git user.email: " GIT_EMAIL
  # Escape backslashes and quotes so names/emails stay valid JSON.
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{ "name": "%s", "email": "%s" }\n' "$(esc "$GIT_NAME")" "$(esc "$GIT_EMAIL")" \
    > "$GITUSER_FILE"
  echo "    saved to $GITUSER_FILE"
else
  echo "==> Git identity already present at $GITUSER_FILE (leaving it as-is)"
fi

echo "==> Step 1: Determinate Nix"
if command -v nix >/dev/null 2>&1; then
  echo "    nix already installed, skipping"
else
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

echo "==> Step 2: symlink this repo to ~/.dotfiles"
# home.nix resolves its mkOutOfStoreSymlink paths through ~/.dotfiles, so this
# has to exist before the first switch or the build will fail to find them.
ln -sfn "$DIR" ~/.dotfiles

# --impure (used by every eval/build below) so the flake can read the
# (gitignored) git identity file.
export DOTFILES_GITUSER_FILE="$GITUSER_FILE"

if [ "$OS" = "Linux" ]; then
  # --- Linux: standalone home-manager ---------------------------------------
  # Validate the requested homeConfiguration exists before building.
  if ! nix eval --impure --raw \
      "$DIR#homeConfigurations.\"$CONFIG\".activationPackage.outPath" >/dev/null 2>&1; then
    echo "error: '$CONFIG' is not a homeConfiguration in flake.nix." >&2
    echo "       available configurations:" >&2
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
      # Guard chsh so a wrong password / cancel doesn't abort under `set -e`.
      if chsh -s "$ZSH_PATH"; then
        echo "    login shell set to $ZSH_PATH (log out/in for it to take effect)"
      else
        echo "    warning: chsh failed; set it manually: chsh -s $ZSH_PATH" >&2
      fi
    else
      echo "    login shell already $ZSH_PATH"
    fi
  else
    echo "    warning: $ZSH_PATH not found; skipping chsh (is zsh in home.packages for $CONFIG?)" >&2
  fi

  echo "==> Done. Use ./rebuild.sh for future changes."
  exit 0
fi

# --- macOS: nix-darwin ------------------------------------------------------
# Fail early if the requested configuration doesn't exist in the flake, before
# we hand it to darwin-rebuild (which would otherwise fail more cryptically).
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
# darwin-rebuild doesn't exist yet on a fresh machine, so run it straight
# from the flake this once. After this, rebuild.sh works normally.
# This fetches the darwin-rebuild tool from the nix-darwin-26.05 release branch,
# not the exact flake.lock revision. The system config it applies is still pinned
# by this repo's flake.lock.
# sudo resets PATH to a secure default that excludes /nix/.../bin, so a
# freshly installed `nix` would not be found under sudo even though it's
# on PATH here. Resolve the absolute path first and invoke that instead.
# --impure lets the flake read the gitignored identity file; the inline
# VAR=val form injects it past sudo's env reset so the eval can find it.
# The home-manager activation step is launched by the darwin activate script as
# `sudo -u <user> --set-home ...`. On a machine with a managed sudoers
# `secure_path` (e.g. MDM/CyberArk), that inner sudo strips /nix/... from PATH,
# so home-manager's `dirname $(readlink $(type -p nix-env))` self-location comes
# back empty and activation dies with "nix-build: command not found". We can't
# edit the managed sudoers, but secure_path always includes /usr/local/bin, so
# we drop a stable symlink to nix-env there for the activation to find. Points
# at the profile path (not a store path) so it survives nix upgrades. rebuild.sh
# does the same before every switch; this is the fresh-machine equivalent.
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
# If this still fails with "nix: command not found", open a new terminal
# (Determinate adds nix to new shells' PATH) and re-run ./bootstrap.sh.

echo "==> Done. Use ./rebuild.sh for future changes."
