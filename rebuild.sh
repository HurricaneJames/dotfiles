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

# --impure + inline VAR=val so the flake can read the gitignored identity file
# even though sudo resets the environment.
exec sudo DOTFILES_GITUSER_FILE="$GITUSER_FILE" \
  darwin-rebuild switch --impure --flake "$DIR#$CONFIG"
