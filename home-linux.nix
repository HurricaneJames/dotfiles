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
