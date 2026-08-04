#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_FILE="$DIR/.dotfiles-profile"
GITUSER_FILE="$DIR/.dotfiles-gituser.json"
OS="$(uname -s)"   # Darwin or Linux

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
  if [ "$OS" = "Linux" ]; then
    nix eval --impure --raw "$DIR#homeConfigurations.\"$1\".activationPackage.outPath" >/dev/null 2>&1
  else
    nix eval --impure --raw "$DIR#darwinConfigurations.$1.system.outPath" >/dev/null 2>&1
  fi
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
    if [ "$OS" = "Linux" ]; then
      nix eval --impure --apply builtins.attrNames "$DIR#homeConfigurations" --json 2>/dev/null
    else
      nix eval --impure --apply builtins.attrNames "$DIR#darwinConfigurations" --json 2>/dev/null
    fi | tr -d '[]"' | tr ',' '\n'
  )
  [ "${#CONFIGS[@]}" -gt 0 ] || {
    if [ "$OS" = "Linux" ]; then
      echo "error: no homeConfigurations found in flake.nix" >&2
    else
      echo "error: no darwinConfigurations found in flake.nix" >&2
    fi
    exit 1
  }
  select choice in "${CONFIGS[@]}"; do
    [ -n "${choice:-}" ] && { CONFIG="$choice"; break; }
    echo "Please pick a number from the list." >&2
  done
  printf '%s\n' "$CONFIG" > "$PROFILE_FILE"
  echo "==> Saved configuration '$CONFIG' to $PROFILE_FILE"
fi

# Reconcile the dx-managed AI tooling (Anduril work machines, mac and Linux).
#
# These tools aren't nix-managed: dx installs their binaries into its own data
# dir (`dx env` prints the path - ~/Library/Application Support/dx/bin on mac,
# ~/.local/share/dx/bin on Linux) and owns ~/.claude/settings.json and
# ~/.pi/agent/settings.json. The Bifrost gateway enforces a minimum claude
# version, so leaving this to drift means a tool that stops talking to the
# gateway. Running it here keeps "rebuild.sh brought this machine up to date"
# true for the AI tooling too, not just the nix closure.
#
# dx follows the home-manager symlink chain and merges into the real file in
# this repo (it prints "Following symlink: ..."), so gateway settings it
# changes land as a reviewable git diff rather than being lost on next switch.
#
# dx itself is updated first, and that ordering is load-bearing: an old dx
# writes an OLD config over the repo's file (a stale dx rewrote the model pins
# backwards here once). Reconciling with a stale dx is worse than not
# reconciling, so the update is what makes the rest of this safe.
#
# The tool BINARIES need their own update step: neither reconcile path below
# upgrades them, and they can't upgrade themselves. `dx ai pi --setup` only
# checks that pi is *present* ("Checking pi installation") and then writes
# config, so it happily left pi at 0.80.6 while 0.83.0 was current. pi's own
# `pi update` can't fix that either - dx ships pi as a Bun single-file binary,
# and pi's updater hard-refuses that install shape ("cannot self-update this
# installation", pointing at GitHub releases) because it only knows how to
# upgrade npm/pnpm/yarn/bun package installs. `dx module install` is the only
# thing that moves these versions, so without it the binaries silently drift
# while their configs stay reconciled - and the Bifrost gateway enforces a
# minimum claude version, so that drift eventually breaks the tools.
#
# claude: --migrate is the full reconcile (version check, gateway validation,
#   settings merge, plus purging any leftover Bedrock config).
# pi:     has no --migrate; --setup is its reconcile path. Its authorization
#   phase may open a browser to establish the Bifrost session - that's wanted
#   here, since a rebuild is exactly when a stale session should get renewed.
#
# pi deliberately gets no --interactive flag, so it defaults to `auto`: it can
# prompt (and open a browser) from a terminal, and degrades instead of hanging
# when there's no TTY, e.g. an unattended rebuild.
#
# Non-fatal by design: an offline or unauthenticated rebuild should still
# finish the nix switch rather than failing at the last step.
reconcile_dx_ai() {
  local dx="$HOME/go/bin/dx"
  [ -x "$dx" ] || return 0

  echo "==> dx: updating dx itself"
  "$dx" update --interactive=no \
    || echo "dx: self-update failed (offline? run '$dx update' later)"

  echo "==> dx: updating AI tool binaries (claude, pi)"
  "$dx" module install claude pi --interactive=no \
    || echo "dx: module install failed (offline? run '$dx module install claude pi' later)"

  echo "==> dx: reconciling AI tooling (claude, pi)"
  "$dx" ai claude --migrate --quiet --interactive=no \
    || echo "dx: claude reconcile failed (offline? run '$dx ai claude --migrate' later)"
  "$dx" ai pi --setup \
    || echo "dx: pi reconcile failed (offline? run '$dx ai pi --setup' later)"

  # Each run writes a settings.backup.<epoch>.json next to the config; without
  # this they accumulate one per rebuild, forever.
  "$dx" ai claude --clean --interactive=no >/dev/null 2>&1 || true
  "$dx" ai pi --clean --interactive=no >/dev/null 2>&1 || true
}

if [ "$OS" = "Linux" ]; then
  # Standalone home-manager: no sudo, no secure_path dance, no darwin-rebuild.
  # Prefer the installed CLI; fall back to `nix run` when it isn't on PATH yet
  # (e.g. the very first rebuild, before the profile is on this shell's PATH).
  # --impure so the flake can read the gitignored identity file.
  #
  # Not `exec` - reconcile_dx_ai runs after the switch, as it does on mac.
  if command -v home-manager >/dev/null 2>&1; then
    home-manager switch --impure --flake "$DIR#$CONFIG"
  else
    nix run github:nix-community/home-manager/release-26.05 -- \
      switch --impure --flake "$DIR#$CONFIG"
  fi

  reconcile_dx_ai
  exit 0
fi

# --- macOS: nix-darwin (everything below is unchanged) ----------------------

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
#
# Not `exec` - there's a post-switch step below.
sudo DOTFILES_GITUSER_FILE="$GITUSER_FILE" \
  "$DARWIN_REBUILD" switch --impure --flake "$DIR#$CONFIG"

reconcile_dx_ai
