# Linux (standalone home-manager) wrapper: imports the shared config and adds
# the Linux-only bits. `herdr`/`wezterm`/`claude-code` come from Homebrew on
# mac; on Linux there is no Homebrew, so they install as Nix packages here.
{ gitUser, envFile, nixGL, treehouse }:

{ config, pkgs, lib, ... }:

{
  imports = [ (import ./home-common.nix {
    inherit gitUser envFile treehouse;
    homeDirectory = "/home/jburnett";
    # wezterm is a GUI app: on Ubuntu (non-NixOS) it can't reach the system GPU
    # driver on its own, so wrap it with nixGL (see targets.genericLinux.nixGL
    # below). herdr/claude-code are CLI-only and need no wrapping.
    extraPackages = [ (config.lib.nixGL.wrap pkgs.wezterm) ]
      ++ (with pkgs; [ herdr claude-code ]);
  }) ];

  home.username = "jburnett";
  home.stateVersion = "24.11";

  # Non-NixOS integration. `enable` puts ~/.nix-profile/share on XDG_DATA_DIRS
  # so GNOME lists the wezterm .desktop entry, and points GL-using apps at a
  # working driver. `nixGL.packages` + the default `mesa` wrapper make
  # `config.lib.nixGL.wrap` actually wrap (it's a no-op until packages is set).
  # Mesa/Intel iGPU is used deliberately: a terminal doesn't need the discrete
  # NVIDIA GPU, and the mesa wrapper avoids pinning the exact NVIDIA driver
  # version (and the --impure nvidia wrapper needs).
  targets.genericLinux.enable = true;
  targets.genericLinux.nixGL.packages = nixGL.packages;

  # Standalone home-manager: install the `home-manager` CLI into the user
  # profile so rebuild.sh can call it directly. On mac the darwin module
  # provides the tooling instead, so this is Linux-only.
  programs.home-manager.enable = true;

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
