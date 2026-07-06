#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_FILE="$DIR/.dotfiles-profile"
GITUSER_FILE="$DIR/.dotfiles-gituser.json"

ln -sfn "$DIR" ~/.dotfiles

# The git identity file is required - flake.nix reads name/email from it.
# bootstrap.sh creates it; if it's missing this machine was never bootstrapped.
if [ ! -f "$GITUSER_FILE" ]; then
  echo "error: $GITUSER_FILE is missing." >&2
  echo "       Run ./bootstrap.sh first - it prompts for your git name/email." >&2
  exit 1
fi
# flake.nix reads the identity file from this env var (--impure below).
export DOTFILES_GITUSER_FILE="$GITUSER_FILE"

# The home-manager activation step is launched by the darwin activate script as
# `sudo -u <user> --set-home ...`. On a machine with a managed sudoers
# `secure_path` (e.g. MDM/CyberArk), that inner sudo strips /nix/... from PATH,
# so home-manager's `dirname $(readlink $(type -p nix-env))` self-location comes
# back empty and activation dies with "nix-build: command not found". We can't
# edit the managed sudoers, but secure_path always includes /usr/local/bin, so
# we drop a stable symlink to nix-env there for the activation to find. Points
# at the profile path (not a store path) so it survives nix upgrades. No-op on
# machines where nix is already reachable.
ensure_nix_on_secure_path() {
  local nix_env
  nix_env="$(command -v nix-env 2>/dev/null)" || return 0
  [ -n "$nix_env" ] || return 0
  # /nix/var/nix/profiles/default/bin/nix-env is the stable, upgrade-proof path.
  local stable="/nix/var/nix/profiles/default/bin/nix-env"
  [ -e "$stable" ] && nix_env="$stable"
  if [ "$(readlink /usr/local/bin/nix-env 2>/dev/null)" != "$nix_env" ]; then
    sudo mkdir -p /usr/local/bin
    sudo ln -sfn "$nix_env" /usr/local/bin/nix-env
  fi
}

# Confirm a configuration name actually exists in flake.nix.
config_exists() {
  nix eval --impure --raw "$DIR#darwinConfigurations.$1.system.outPath" >/dev/null 2>&1
}

# Use the configuration chosen at bootstrap time. If none was saved (or it no
# longer exists in the flake), ask which one to use and save it the same way
# bootstrap.sh does.
CONFIG=""
if [ -f "$PROFILE_FILE" ]; then
  CONFIG="$(tr -d '[:space:]' < "$PROFILE_FILE")"
fi

if [ -z "$CONFIG" ] || ! config_exists "$CONFIG"; then
  [ -n "$CONFIG" ] && echo "Saved profile '$CONFIG' is not in flake.nix anymore." >&2
  echo "Which configuration should this machine use?"
  CONFIGS=()
  while IFS= read -r line; do
    [ -n "$line" ] && CONFIGS+=("$line")
  done < <(
    nix eval --impure --apply builtins.attrNames "$DIR#darwinConfigurations" --json 2>/dev/null \
      | tr -d '[]"' | tr ',' '\n'
  )
  [ "${#CONFIGS[@]}" -gt 0 ] || { echo "error: no darwinConfigurations found in flake.nix" >&2; exit 1; }
  select choice in "${CONFIGS[@]}"; do
    [ -n "${choice:-}" ] && { CONFIG="$choice"; break; }
    echo "Please pick a number from the list." >&2
  done
  printf '%s\n' "$CONFIG" > "$PROFILE_FILE"
  echo "==> Saved configuration '$CONFIG' to $PROFILE_FILE"
fi

# Make nix-env reachable from the home-manager activation step (see the helper).
ensure_nix_on_secure_path

# Resolve darwin-rebuild to an absolute path. sudo locates the command it runs
# via the sudoers `secure_path`, NOT via any PATH= we pass; on a machine with a
# managed secure_path (e.g. MDM/CyberArk) it excludes /run/current-system/sw/bin
# and `sudo darwin-rebuild` fails with "command not found". Invoking the
# absolute path skips sudo's PATH lookup entirely (same trick bootstrap.sh uses
# for the nix binary).
DARWIN_REBUILD="$(command -v darwin-rebuild)"

# --impure + inline VAR=val so the flake can read the gitignored identity file
# even though sudo resets the environment.
exec sudo DOTFILES_GITUSER_FILE="$GITUSER_FILE" \
  "$DARWIN_REBUILD" switch --impure --flake "$DIR#$CONFIG"
