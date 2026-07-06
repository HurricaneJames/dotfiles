# `envFile` is an optional path to an environment-specific config (or null).
# When set it layers extra home packages, zsh session variables and zsh init
# content onto the shared base. See configuration-studiob.nix for the schema.
{ gitUser, envFile }:

{ config, pkgs, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  env = if envFile == null then { } else import envFile { inherit pkgs; };
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
    # languages / runtimes
    python314
    # git tooling (git itself is installed via programs.git below)
    git-lfs
    # containers — docker-client is CLI + compose plugin + buildx + shell
    # completions; the actual daemon runs in the colima VM on macOS.
    docker-client
    docker-compose
    colima                        # rootless container runtime VM for macOS
    amazon-ecr-credential-helper  # docker-credential-ecr-login for AWS ECR
    # the font everything renders in
    nerd-fonts.hack
  ] ++ (env.homePackages or [ ]);
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  programs.zsh = {
    enable = true;
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

  # Edit-in-place: the real file stays in my repo, ~/.config just points at it.
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  home.file.".claude/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";

  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".codex/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".config/opencode/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
}
