# Environment-specific config file overrides

## Problem

`home.nix` wires `home.file.<target>.source` symlinks from fixed sources in the
dotfiles repo. Some environments need a different source for a given target. For
example, StudioB needs its own `.claude/settings.json`. Today this is a manual
hack: the base `home.file.".claude/settings.json".source` line was edited in
place to point at `settings.studiob.json`, which is wrong for the base (Studio1)
profile and doesn't scale to more environments.

We want an environment to override the source of specific config files without
touching the shared base.

## Approach

Explicit declaration in the environment file. The env file
(`configuration-studiob.nix`) already is the schema for "what this environment
changes" (packages, casks, zsh vars), so config-file overrides fit there as a
new optional field. No filesystem naming conventions or existence checks - the
env file is the single source of truth for what it overrides.

## Design

### Env file schema addition

The env file gains an optional `configOverrides` attrset, keyed by the target
path relative to `$HOME`, valued by the source path relative to the dotfiles
repo root:

```nix
configOverrides = {
  ".claude/settings.json" = "home/.claude/settings.studiob.json";
};
```

Consistent with the existing `env.<field> or <default>` convention, the field
is optional; environments that override nothing omit it.

### home.nix restructure

The current imperative `home.file.".../".source = mkOutOfStoreSymlink ...` lines
are refactored into a single base attrset of `target -> repo-relative-source`,
merged with the env overrides via `//`, then mapped into `home.file` entries:

```nix
let
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
  home.file = builtins.mapAttrs
    (target: src: {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${src}";
    })
    configFiles;
}
```

home.nix owns the `${dotfiles}/` prefix; sources everywhere are repo-relative
strings, keeping one convention.

### Behavior

- A key present in `configOverrides` replaces the base source.
- The `//` merge also allows an environment to add a brand-new file the base
  doesn't have.
- The base `.claude/settings.json` reverts to `home/.claude/settings.json`
  (undoing the manual StudioB hack). StudioB's override moves into
  `configuration-studiob.nix` via `configOverrides`.

## Out of scope

- Convention/auto-detection of override files by filename.
- Overriding anything other than `home.file` source symlinks (packages, casks,
  zsh vars already have their own env fields).
