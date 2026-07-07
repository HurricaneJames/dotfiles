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
  # Use the Nix zsh (5.9.1) as the login shell so it, tmux's default-shell, and
  # everything on $PATH are the same binary. Otherwise Apple's /bin/zsh (5.9)
  # and the Nix zsh share one ~/.zcompdump; each rejects the other's version and
  # rebuilds the ~1000-entry cache on every alternating launch (2-9s of stat()).
  environment.shells = [ pkgs.zsh ];
  users.users.jburnett = {
    home = "/Users/jburnett";
    shell = pkgs.zsh;
  };

  # New-terminal startup was ~0.8s warm / ~4s cold. The cost was the plain
  # `compinit` nix-darwin puts in /etc/zshrc: it runs `compaudit` (a security
  # stat() over all ~20 fpath dirs, most in the Nix store) on EVERY launch,
  # even when ~/.zcompdump is valid - ~600ms warm, seconds cold. `compinit -C`
  # skips that audit and just sources the cached dump.
  #
  # So: disable the global compinit and run our own from interactiveShellInit.
  # Fast path (`-C`) when the dump is <24h old; a full rebuild+audit otherwise,
  # then touch the dump to reset the 24h clock. New completions installed by a
  # rebuild still get picked up within a day (and immediately on a fresh dump).
  programs.zsh.enableGlobalCompInit = false;
  programs.zsh.interactiveShellInit = ''
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
