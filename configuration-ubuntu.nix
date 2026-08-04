# Environment-specific config for the Ubuntu work machine.
#
# flake.nix wires this in via `mkLinuxHome ./configuration-ubuntu.nix`.
# Every field below is optional - home-common.nix reads them with
# `env.<field> or <default>`, so you can drop any you don't need.
{ pkgs, ... }:

{
  # Extra home-manager packages (appended to home-common.nix's home.packages).
  homePackages = with pkgs; [
    go                            # golang for work
    kubectl
    amazon-ecr-credential-helper  # docker-credential-ecr-login for AWS ECR
  ];

  # No casks/brews on Linux - there is no Homebrew layer. Those fields are
  # simply omitted (home-common.nix never reads them; only configuration.nix on
  # mac does).

  # Override the source of specific home.file config symlinks for this env.
  # Work needs its own Claude settings (same file StudioB uses).
  configOverrides = {
    ".claude/settings.json" = "home/.claude/settings.studiob.json";
  };

  # Extra zsh session variables (merged into home-common.nix's sessionVariables).
  # For non-secret values only - these are baked into the world-readable
  # /nix/store. Secrets belong in zshInitContent below (read at shell startup).
  zshSessionVariables = {
    NIX_PATH = "/home/jburnett/sources/anduril-nixpkgs";
  };

  # Appended to home-common.nix's zsh initContent, run at every shell startup.
  #
  # There is no macOS Keychain on Linux, so GHE_API_TOKEN is read from a
  # gitignored file rather than a keychain. The token never lands in the
  # world-readable /nix/store (Nix only bakes in the `cat` line, not its
  # output). One-time setup on this machine:
  #
  #     mkdir -p ~/.config/dotfiles
  #     printf '%s' "<token>" > ~/.config/dotfiles/ghe-token
  #     chmod 600 ~/.config/dotfiles/ghe-token
  zshInitContent = ''
    [ -r "$HOME/.config/dotfiles/ghe-token" ] && \
      export GHE_API_TOKEN="$(cat "$HOME/.config/dotfiles/ghe-token")"

    # dx-managed tool binaries (claude, authorization, opencode, pi). This is
    # exactly what `dx env` prints, inlined: that command costs ~25ms of Go
    # process startup per shell just to echo a static string. The path differs
    # from mac's (~/Library/Application Support/dx/bin) - dx is XDG-aware here.
    #
    # Ahead of the Nix profile on purpose - dx enforces the minimum claude
    # version the Bifrost gateway requires, so its copy must be the one that
    # wins. `pi` resolves here too, but keep using the alias below, not the
    # bare binary.
    export PATH="$HOME/.local/share/dx/bin:$PATH"
  '';

  # Extra zsh shell aliases (merged into home-common.nix's shellAliases).
  #
  # pi must go through `dx ai pi`, never the bare binary: the launcher refreshes
  # the Bifrost authorization session so pi's token command can mint
  # non-interactively, and clears the provider env (ANTHROPIC_*, AWS_*, OPENAI_*,
  # GOOGLE_*) that would otherwise route around the gateway. A bare `pi` reaches
  # pi's built-in default provider directly via ambient credentials.
  zshShellAliases = {
    pi = "~/go/bin/dx ai pi";
  };
}
