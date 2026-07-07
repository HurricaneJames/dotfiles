# `envFile` is an optional path to an environment-specific config (or null).
# When set it layers extra home packages, zsh session variables and zsh init
# content onto the shared base. See configuration-studiob.nix for the schema.
{ gitUser, envFile }:

{ config, pkgs, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  env = if envFile == null then { } else import envFile { inherit pkgs; };

  # Config files symlinked edit-in-place: the real file stays in my repo, the
  # target under $HOME just points at it. Keyed by target (relative to $HOME),
  # valued by source (relative to the dotfiles repo root). An environment can
  # replace a source - or add a brand-new file - via `env.configOverrides`
  # (see configuration-studiob.nix); the `//` lets its entries win.
  baseConfigFiles = {
    ".config/wezterm"            = "home/.config/wezterm";
    ".config/nvim"               = "home/.config/nvim";
    ".config/herdr"              = "home/.config/herdr";
    ".claude/settings.json"      = "home/.claude/settings.json";
    ".claude/CLAUDE.md"          = "home/AGENTS.md";
    ".codex/AGENTS.md"           = "home/AGENTS.md";
    ".config/opencode/AGENTS.md" = "home/AGENTS.md";
  };
  configFiles = baseConfigFiles // (env.configOverrides or { });
in

{
  home.username = "jburnett";
  home.homeDirectory = "/Users/jburnett";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    mosh
    # languages / runtimes
    python314
    # git tooling (git itself is installed via programs.git below)
    gh
    git-lfs
    # containers — docker-client is CLI + compose plugin + buildx + shell
    # completions; the actual daemon runs in the colima VM on macOS.
    docker-client
    docker-compose
    colima                        # rootless container runtime VM for macOS
    # the font everything renders in
    nerd-fonts.hack
  ] ++ (env.homePackages or [ ]);
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  programs.zsh = {
    enable = true;
    enableCompletion = false;          # /etc/zshrc (nix-darwin) already runs compinit; avoid a 2nd ~3s compinit
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      setopt nomenucomplete
      setopt noautomenu
      bindkey '^f' autosuggest-accept
    '' + (env.zshInitContent or "");
    sessionVariables = {
      CLICOLOR = "1";
    } // (env.zshSessionVariables or { });
    shellAliases = {
      ".." = "cd ..";
      add = "git add .";
      push = "git push";
      pull = "git pull";
      m = "git switch main";
      cc = "claude --dangerously-skip-permissions";
      co = "codex --full-auto";
      k = "kubectl";
    };
  };

  programs.git.enable = true;
  programs.git.settings.user = gitUser;

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  home.file = builtins.mapAttrs
    (target: src: {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${src}";
    })
    configFiles;
}
