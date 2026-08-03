# Jira MCP server for the StudioB profile

## Problem

Work uses a self-hosted Jira Data Center at `jira.anduril.dev`. Claude Code
should be able to read issues from it on the StudioB (work) profile, and only
there - the base (Studio1) profile has no use for it.

This needs a Jira personal access token available to Claude Code without the
token ever entering this public repo, and without it landing in the
world-readable `/nix/store`.

## Constraints discovered

Two findings shaped the design:

- **`settings.json` has no `mcpServers` key.** It is silently ignored if
  present. MCP servers can only be declared in `~/.claude.json` (which Claude
  Code itself writes session and project state into, so it cannot be a symlink
  from this repo), `.mcp.json` (project scope, wrong for a user-level server),
  or a file passed via `--mcp-config`. The `--mcp-config` flag takes a path,
  merges with other MCP config rather than replacing it, and is repeatable.
- **MCP server subprocesses inherit the launching shell's environment.** A
  token exported in `zshInitContent` therefore reaches the server without any
  file on disk holding it.

The second finding means no gitignored secrets file is needed. The original
request was for a gitignored env file supplying `JIRA_PERSONAL_TOKEN`; the
macOS Keychain supplies the same environment variable with no plaintext token
on disk, and reuses the pattern this repo already established for
`GHE_API_TOKEN` and `CIRCLECI_CLI_TOKEN`.

## Approach

Keep the server definition tracked in the repo, keep the token in the
Keychain, and join them at shell startup.

The alternatives were an imperative one-time `claude mcp add` writing into
`~/.claude.json`, and bundling a `.mcp.json` in a local Claude Code plugin.
Both cover every launch path including IDE sessions, which the chosen approach
does not. Both were rejected for this iteration: `claude mcp add` leaves the
configuration invisible to version control and lost on a fresh machine, which
defeats the purpose of this repo; the plugin route needs a separate git repo to
serve as a marketplace, since a local filesystem marketplace source is
unverified. Either remains available later if IDE coverage becomes worthwhile.

## Design

### Token via Keychain

`configuration-studiob.nix` gains a third export in `zshInitContent`, beside
the existing two, with the one-time machine setup documented in the comment
above it:

```nix
export JIRA_PERSONAL_TOKEN="$(security find-generic-password -a "$USER" -s JIRA_PERSONAL_TOKEN -w 2>/dev/null)"
```

One-time setup on the machine, which prompts for the token value:

```
security add-generic-password -a "$USER" -s JIRA_PERSONAL_TOKEN -w
```

Nix bakes in only the `security` command, never its output.

### Tracked server definition

New tracked file `home/.claude/mcp.studiob.json`:

```json
{
  "mcpServers": {
    "jira": {
      "type": "stdio",
      "command": "uvx",
      "args": ["mcp-atlassian"],
      "env": {
        "JIRA_URL": "https://jira.anduril.dev",
        "JIRA_PERSONAL_TOKEN": "${JIRA_PERSONAL_TOKEN}",
        "READ_ONLY_MODE": "true"
      }
    }
  }
}
```

It holds no secret - `${JIRA_PERSONAL_TOKEN}` is expanded by Claude Code from
the shell environment at launch. Listing it in `env` is redundant with
subprocess inheritance but makes the dependency self-documenting and produces a
missing-variable warning in `claude mcp list` when the Keychain read fails.

`sooperset/mcp-atlassian` is the server because Atlassian's own remote MCP
server is Cloud-only. Confluence stays off by omitting all `CONFLUENCE_*`
variables; there is no explicit flag. `READ_ONLY_MODE` keeps Claude from
creating, editing, transitioning, or commenting on issues in shared work
tracking, and is one tracked line to relax later.

The file reaches `~/.claude/mcp.studiob.json` through the existing
`configOverrides` mechanism, which already merges brand-new files and not just
overrides:

```nix
configOverrides = {
  ".claude/settings.json"   = "home/.claude/settings.studiob.json";
  ".claude/mcp.studiob.json" = "home/.claude/mcp.studiob.json";
};
```

### New `zshShellAliases` env hook

`home.nix` currently hardcodes `shellAliases`. It gains an optional env hook,
mirroring the existing `zshSessionVariables` one:

```nix
shellAliases = {
  # ... base aliases unchanged ...
} // (env.zshShellAliases or { });
```

StudioB then overrides `cc` to pass the config file:

```nix
zshShellAliases = {
  cc = "claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.studiob.json";
};
```

### uv package

`uv` is added to StudioB's `homePackages`, providing `uvx` on PATH for the MCP
subprocess to inherit. It stays out of the base profile.

## Behavior and consequences

- Jira tools are available when Claude Code is launched via the `cc` alias.
  Bare `claude` and IDE sessions do not get them.
- `uvx mcp-atlassian` resolves from PyPI on first run, so it needs network
  access and its version is not pinned by the flake.
- If the Keychain entry is missing, the literal `${JIRA_PERSONAL_TOKEN}` is
  passed through and `claude mcp list` warns; the server fails to authenticate
  rather than silently working.
- On the base profile nothing changes: no `uv`, no symlink, no export, and the
  `cc` alias keeps its current definition.

## Out of scope

- IDE and bare-`claude` coverage (would need `claude mcp add` or the plugin
  route).
- Confluence tools.
- Jira write access.
- Pinning the `mcp-atlassian` version through the flake.
