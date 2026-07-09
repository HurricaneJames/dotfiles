{
  description = "dotfiles";

  inputs = {
    # Use `github:NixOS/nixpkgs/nixpkgs-26.05-darwin` to use Nixpkgs 26.05.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # Use `github:nix-darwin/nix-darwin/nix-darwin-26.05` to use Nixpkgs 26.05.
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Linux uses the NixOS channel (the -darwin channel above is macOS-cached),
    # with its own home-manager instance following it.
    nixpkgs-linux.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager-linux.url = "github:nix-community/home-manager/release-26.05";
    home-manager-linux.inputs.nixpkgs.follows = "nixpkgs-linux";
    # herdr is not yet in the 26.05 stable channel; pull it from unstable.
    # Deliberately not `follows`-ed to nixpkgs-linux (it needs the unstable tree);
    # it's still pinned in flake.lock and only moves on `nix flake update`.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs = inputs@{ self, nix-darwin, nix-homebrew, home-manager, nixpkgs
                   , nixpkgs-linux, home-manager-linux, nixpkgs-unstable }:
    let
      # The git identity is machine-local and untracked (a work email must not
      # live in this public repo), so bootstrap.sh writes it and every profile
      # reads it. Because the file is gitignored, Nix can only see it under
      # `--impure` (which rebuild.sh/bootstrap.sh pass) - a pure eval can't
      # reach files outside the flake's git tree.
      #
      # The scripts resolve the file's absolute path via shell tilde expansion
      # (so it works for whatever user runs it, wherever their home lives) and
      # hand it to the sudo'd rebuild in DOTFILES_GITUSER_FILE. We only read it
      # here; we don't try to reconstruct the home dir inside Nix.
      gitUserFile = builtins.getEnv "DOTFILES_GITUSER_FILE";
      gitUser =
        if gitUserFile != "" && builtins.pathExists gitUserFile
        then builtins.fromJSON (builtins.readFile gitUserFile)
        else throw ''
          Git identity file not found (DOTFILES_GITUSER_FILE=${gitUserFile}).
          Run ./bootstrap.sh (or ./rebuild.sh) to create it - it prompts for
          your git name and email and writes them there.
        '';

      # Build a darwin configuration. Every host reads the same machine-local
      # git identity file; the profiles differ only by what that file contains
      # on each machine (home vs work).
      #
      # `envFile` is an optional path to an environment-specific config (e.g.
      # ./configuration-studiob.nix) that layers extra packages, homebrew casks
      # and zsh settings onto the shared base. Pass `null` for a host that only
      # needs the base config. See configuration-studiob.nix for the schema.
      mkHost = envFile: nix-darwin.lib.darwinSystem {
        modules = [
          (import ./configuration.nix { inherit envFile; })
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # If a file home-manager wants to manage already exists (e.g. a
            # ~/.zshrc from a prior setup), rename it to <file>.hm-bak instead
            # of aborting the activation. Lets a machine adopt these dotfiles
            # without hand-removing what was there first.
            home-manager.backupFileExtension = "hm-bak";
            home-manager.users.jburnett = import ./home-darwin.nix { inherit gitUser envFile; };
          }
        ];
      };

      # Build a standalone home-manager configuration for Linux. No nix-darwin
      # layer, so allowUnfree (claude-code) is set on the pkgs import here.
      # herdr is not yet in nixos-26.05; overlay it from nixpkgs-unstable.
      mkLinuxHome = envFile:
        let
          unstable = import nixpkgs-unstable {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
        in
        home-manager-linux.lib.homeManagerConfiguration {
          pkgs = import nixpkgs-linux {
            system = "x86_64-linux";
            config.allowUnfree = true;
            overlays = [ (_: _: { herdr = unstable.herdr; }) ];
          };
          modules = [ (import ./home-linux.nix { inherit gitUser envFile; }) ];
        };
    in {
      darwinConfigurations = {
        "Studio1" = mkHost null;                         # home profile (base only)
        "StudioB" = mkHost ./configuration-studiob.nix;  # work profile (base + extras)
      };

      homeConfigurations = {
        # One fixed entry serves any Linux box (hostname-independent).
        "linux-work" = mkLinuxHome ./configuration-ubuntu.nix;
      };
    };
}
