# Environment-specific config for the StudioB (work) profile.
#
# flake.nix wires this in via `mkHost ./configuration-studiob.nix`; each host
# either points mkHost at a file like this or passes `null` for base-only.
# Every field below is optional - configuration.nix / home.nix read them with
# `env.<field> or <default>`, so you can drop any you don't need.
{ pkgs, ... }:

{
  # Extra home-manager packages (appended to home.nix's home.packages).
  homePackages = with pkgs; [
    go  # golang for work
    kubectl
    amazon-ecr-credential-helper  # docker-credential-ecr-login for AWS ECR
  ];

  # Extra homebrew casks / brews (appended to configuration.nix's homebrew set).
  casks = [ ];
  brews = [
    "circleci"  # CircleCI local CLI
  ];

  # Casks from configuration.nix's base list to NOT install here.
  #
  # dx owns the claude binary on this machine: `dx ai claude --migrate` (run from
  # rebuild.sh) enforces the minimum version the Bifrost gateway requires and
  # installs into ~/Library/Application Support/dx/bin. Keeping the brew cask too
  # gave us two claudes at different versions, with brew's winning on PATH - so
  # dx's version pin governed a binary nobody ran. One installer, one version.
  excludeCasks = [ "claude-code" ];

  # Override the source of specific home.file config symlinks for this env
  # (see home.nix). Keyed by target relative to $HOME, valued by source
  # relative to the dotfiles repo root. Work needs its own Claude settings.
  configOverrides = {
    ".claude/settings.json" = "home/.claude/settings.studiob.json";
  };

  # Extra zsh shell aliases (merged into home.nix's shellAliases).
  #
  # pi must go through `dx ai pi`, never the bare binary: the launcher refreshes
  # the Bifrost authorization session so pi's token command can mint
  # non-interactively, and clears the provider env (ANTHROPIC_*, AWS_*, OPENAI_*,
  # GOOGLE_*) that would otherwise route around the gateway. A bare `pi` reaches
  # pi's built-in default provider directly via ambient credentials.
  zshShellAliases = {
    pi = "~/go/bin/dx ai pi";
  };

  # Extra zsh session variables (merged into home.nix's sessionVariables).
  # For non-secret values only - these are baked into the world-readable
  # /nix/store. Secrets belong in zshInitContent below (read at shell startup).
  zshSessionVariables = {
    NIX_PATH = "/Users/jburnett/sources/anduril-nixpkgs";
  };

  # Appended to home.nix's zsh initContent, run at every shell startup.
  #
  # GHE_API_TOKEN is pulled from the macOS login Keychain at startup rather
  # than being written here, so the token itself never lands in the
  # world-readable /nix/store (Nix only bakes in the `security` command, not
  # its output). One-time setup on this machine:
  #
  #     security add-generic-password -a "$USER" -s GHE_API_TOKEN -w
  #
  # (that prompts for the token value and stores it in the login keychain;
  # the first read pops an "allow access" dialog - click "Always Allow").
  #
  # CIRCLECI_CLI_TOKEN is handled the same way for the CircleCI CLI. One-time
  # setup on this machine:
  #
  #     security add-generic-password -a "$USER" -s CIRCLECI_CLI_TOKEN -w
  #
  zshInitContent = ''
    export GHE_API_TOKEN="$(security find-generic-password -a "$USER" -s GHE_API_TOKEN -w 2>/dev/null)"
    export CIRCLECI_CLI_TOKEN="$(security find-generic-password -a "$USER" -s CIRCLECI_CLI_TOKEN -w 2>/dev/null)"

    # dx-managed tool binaries (claude, authorization, opencode, pi). This is
    # exactly what `dx env` prints, inlined: that command costs ~25ms of Go
    # process startup per shell just to echo a static string.
    #
    # Ahead of /opt/homebrew/bin on purpose - dx enforces the minimum claude
    # version the Bifrost gateway requires, so its copy must be the one that
    # wins. `pi` resolves here too, but keep using the alias below, not the
    # bare binary.
    export PATH="$HOME/Library/Application Support/dx/bin:$PATH"
  '';
}
