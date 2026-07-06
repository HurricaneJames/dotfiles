# `envFile` is an optional path to an environment-specific config (or null).
# When set, its `casks`/`brews` lists are appended to the shared homebrew set.
# See configuration-studiob.nix for the full schema.
{ envFile }:

{ pkgs, ... }:

let
  env = if envFile == null then { } else import envFile { inherit pkgs; };
in

{
  # Determinate already manages the Nix daemon, so nix-darwin shouldn't.
  nix.enable = false;

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin"; # use x86_64-darwin for Intel CPU

  system.primaryUser = "jburnett";
  users.users.jburnett = {
    home = "/Users/jburnett";
  };
  system.stateVersion = 6;
  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      KeyRepeat = 2;          # fast key repeat
      InitialKeyRepeat = 15;  # short delay before repeat
      #_HIHideMenuBar = false;  # auto-hide the menu bar
      AppleShowAllExtensions = true;
    };
    dock.autohide = true;
    finder.FXPreferredViewStyle = "Nlsv";  # list view by default
    finder.CreateDesktop = false;          # clean desktop
    trackpad.Clicking = true;              # tap to click
  };
  nix-homebrew = {
    enable = true;
    user = "jburnett";
  };
  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";  # remove anything not listed here
    onActivation.autoUpdate = true;
    onActivation.extraFlags = [ "--force" ];
    brews = [
      "herdr"
    ] ++ (env.brews or [ ]);
    casks = [
      "wezterm"
      "claude-code"
    ] ++ (env.casks or [ ]);
  };
}
