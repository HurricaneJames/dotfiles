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
  ];

  # Extra homebrew casks / brews (appended to configuration.nix's homebrew set).
  casks = [ ];
  brews = [ ];

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
  zshInitContent = ''
    export GHE_API_TOKEN="$(security find-generic-password -a "$USER" -s GHE_API_TOKEN -w 2>/dev/null)"
  '';
}
