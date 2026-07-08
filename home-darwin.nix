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
