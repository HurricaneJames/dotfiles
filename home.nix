# `envFile` is an optional path to an environment-specific config (or null).
# When set it layers extra home packages, zsh session variables and zsh init
# content onto the shared base. See configuration-studiob.nix for the schema.
{ gitUser, envFile, treehouse }:

{ config, pkgs, lib, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  env = if envFile == null then { } else import envFile { inherit pkgs; };

  # nvm isn't in nixpkgs (it's an imperative, shell-sourced version manager that
  # downloads node binaries into $NVM_DIR at runtime - fine on macOS). We pin the
  # upstream repo and source nvm.sh from the store; node versions still install
  # into the writable ~/.nvm. Bump `rev` + `hash` to upgrade nvm itself.
  nvmSrc = pkgs.fetchFromGitHub {
    owner = "nvm-sh";
    repo = "nvm";
    rev = "v0.40.5";
    hash = "sha256-bcHoRW3BzvWZYwVyhtYWl8erpgOp4l30JW4XOaGZMQ0=";
  };

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
    pnpm                          # node package manager (node itself via nvm, below)
    # git tooling (git itself is installed via programs.git below)
    gh
    git-lfs
    # containers — docker-client is CLI + compose plugin + buildx + shell
    # completions; the actual daemon runs in the colima VM on macOS.
    docker-client
    docker-compose
    colima                        # rootless container runtime VM for macOS
    # worktree-pool manager (from its own flake, not nixpkgs)
    treehouse.packages.${pkgs.stdenv.hostPlatform.system}.default
    # the font everything renders in
    nerd-fonts.hack
  ] ++ (env.homePackages or [ ]);
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  # On first activation (when nvm arrives / ~/.nvm has no default yet), install
  # the latest LTS ("stable") node and make it the default. Idempotent: once a
  # default alias exists we skip it, so later rebuilds don't re-download. Kept
  # non-fatal - an offline rebuild just warns instead of failing activation.
  home.activation.nvmDefaultNode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export NVM_DIR="${config.home.homeDirectory}/.nvm"
    $DRY_RUN_CMD mkdir -p "$NVM_DIR"
    if [ ! -e "$NVM_DIR/alias/default" ]; then
      export PATH="${lib.makeBinPath [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.coreutils ]}:$PATH"
      echo "nvm: installing latest LTS node as default (first-time setup)..."
      $DRY_RUN_CMD ${pkgs.bash}/bin/bash -c '. "${nvmSrc}/nvm.sh" --no-use && nvm install --lts --default --no-progress' \
        || echo "nvm: node install failed (offline?) - run 'nvm install --lts --default' later"
    fi
  '';

  programs.zsh = {
    enable = true;
    enableCompletion = false;          # /etc/zshrc (nix-darwin) already runs compinit; avoid a 2nd ~3s compinit
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      setopt nomenucomplete
      setopt noautomenu
      bindkey '^f' autosuggest-accept

      # Ctrl+Left / Ctrl+Right = move by word. WezTerm sends the xterm
      # modified-arrow sequences (ESC[1;5D / ESC[1;5C); without these binds
      # zsh has no match and leaks the ";5D"/";5C" tail as literal text.
      bindkey '^[[1;5D' backward-word
      bindkey '^[[1;5C' forward-word

      # nvm, lazy-loaded: sourcing nvm.sh eagerly adds ~100-300ms to every shell
      # start, so instead we install thin shims that source it (from the pinned
      # store copy) on first use of nvm/node/npm/npx, then hand off to the real
      # command. Sourcing auto-activates the `default` alias, so node lands on PATH.
      export NVM_DIR="$HOME/.nvm"
      _nvm_lazy() { unset -f nvm node npm npx 2>/dev/null; . "${nvmSrc}/nvm.sh"; }
      nvm()  { _nvm_lazy; nvm "$@"; }
      node() { _nvm_lazy; node "$@"; }
      npm()  { _nvm_lazy; npm "$@"; }
      npx()  { _nvm_lazy; npx "$@"; }
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
