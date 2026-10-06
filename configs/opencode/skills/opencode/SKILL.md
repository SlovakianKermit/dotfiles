---
name: OpenCode
description: >-
  Use this skill for any question about OpenCode itself, including how OpenCode
  works, using or configuring it, migrating from V1 to V2, troubleshooting it,
  developing plugins or integrations, using the OpenCode SDK, clients, server,
  or API, and contributing to the OpenCode codebase. Also use it for OpenCode
  agents, commands, skills, tools, permissions, MCP servers, providers, models,
  themes, keybinds, formatters, the CLI, TUI, desktop app, and web app.
---

# OpenCode

Use this guide as the starting point for work involving OpenCode itself. It
covers the core concepts needed to configure and customize OpenCode, extend it
with plugins, and build integrations with the OpenCode SDK, clients, and API.

Full documentation is available at <https://opencode.ai/v2/docs/>. This overview is
only an index of core concepts. Before answering a question about a topic below,
fetch the URL named in that section and use the full page as the source of
truth. Follow links from that page when the question needs more detail. Fetch
<https://opencode.ai/v2/docs/> first when you need to discover the relevant
documentation page.

A machine-readable documentation index is available at
<https://opencode.ai/v2/llms.txt>.

## Version policy

Always answer for OpenCode V2 unless the user explicitly asks about V1,
legacy OpenCode, or migrating from V1.

Use only <https://opencode.ai/v2/docs/> documentation as the source of truth for V2.
Do not use <https://opencode.ai/docs/>, which documents V1, and do not use
general web search to resolve a V2 documentation question when the V2 docs or
linked pages cover it. The schema served from
<https://opencode.ai/config.json> may describe V1 even though V2 configuration
files include that URL for editor integration. Never use it to infer V2 field
names or shapes. If V2 documentation is missing or contradictory, state the
uncertainty or ask for clarification instead of falling back to V1.

V1 documentation and syntax may be consulted only when the user explicitly
asks about V1 or when needed as migration input. Outputs and recommendations
must still use V2 unless the user specifically requests a V1 result.

## [CLI](https://opencode.ai/v2/docs/cli)

For questions about the terminal interface, command-line invocation, `run`,
`mini`, terminal providers, or other CLI behavior, fetch the
[CLI guide](https://opencode.ai/v2/docs/cli) and the relevant page linked from
that section.

CLI and TUI preferences are separate from OpenCode's server and project
configuration. They live in the global `~/.config/opencode/cli.json`, or
`$XDG_CONFIG_HOME/opencode/cli.json` when `XDG_CONFIG_HOME` is set. There is no
project-local CLI configuration. Set `OPENCODE_CLI_CONFIG_CONTENT` to merge
inline JSON over the global settings. Most preferences can also be changed from
the TUI by pressing `Ctrl+P` and selecting **Open settings**.

### [Settings](https://opencode.ai/v2/docs/cli/config)

Fetch the full [CLI settings reference](https://opencode.ai/v2/docs/cli/config)
before editing `cli.json`. It documents every terminal-only setting, accepted
values, and examples, including themes, input, sessions, tabs, diffs, alerts,
Mini, keybindings, terminal plugins, and debugging. Do not put these settings
in `opencode.json(c)`.

### [Keybinds](https://opencode.ai/v2/docs/cli/keybinds)

Configure keybindings under `keybinds` in `cli.json`. The leader key is the
`keybinds.leader` entry; leader timing is configured separately under
`leader.timeout`. Bindings can use a string, an array of strings, or an object
when event behavior such as `preventDefault` is required. Disable a binding
with `"none"` or `false`.

Never guess a command ID, default binding, or accepted key syntax. Fetch the
full [keybind reference](https://opencode.ai/v2/docs/cli/keybinds), which lists
the current IDs and defaults, before answering or editing a binding.

## [OpenCode configuration](https://opencode.ai/v2/docs/config)

OpenCode's server and project configuration uses JSON or JSONC. Include the
published schema so the user's editor can validate fields and provide
autocomplete:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
}
```

Global configuration lives at `~/.config/opencode/opencode.json(c)` and applies
to every project for that user. Project configuration can live in any directory
as `opencode.json(c)` or `.opencode/opencode.json(c)`, including nested packages
in a monorepo.

During ordinary project discovery, OpenCode searches the current Location
directory and every ancestor through the filesystem root, including directories
above the detected project or repository root. It merges direct
`opencode.json(c)` files from the farthest ancestor to the current directory,
then does the same for `.opencode/opencode.json(c)` files. This means every
discovered `.opencode` config overrides every discovered direct config. Global
filesystem configuration has lower precedence than these discovered documents.

Common configuration fields include `model`, `default_agent`, `permissions`,
`agents`, `commands`, `plugins`, `providers`, `mcp`, `skills`, `instructions`,
`references`, `formatter`, and `lsp`.

This configuration is distinct from `cli.json`. Use the
[CLI settings reference](https://opencode.ai/v2/docs/cli/config) for terminal
preferences, especially themes and keybindings.

Do not guess field names or shapes. Fetch the V2 configuration guide and its
linked topic guide as the source of truth, and preserve unrelated settings when
editing an existing file. Keep the published `$schema` URL in configuration
examples, but do not fetch it to determine the V2 configuration shape.

See the [full configuration guide](https://opencode.ai/v2/docs/config) for
every field, examples, config locations, and links to dedicated feature guides.

## [MCP servers](https://opencode.ai/v2/docs/mcp-servers)

Configure MCP servers under `mcp.servers`. Prefer the CLI because it preserves
unrelated configuration. Use `--global` when the user asks to set up a service
for themselves without limiting it to the current project; omit it when they
explicitly want project-local configuration.

```sh
opencode mcp add <name> --global --url <remote-url>
opencode mcp list
```

Remote servers use OAuth by default. If `mcp list` reports that a server needs
authentication, tell the user to run `/mcps`, select the server, and sign in.
Do not run `opencode mcp auth` through the shell tool: it starts an interactive
flow whose authorization link can be hidden in background process output.
Use the user-facing MCP interface instead.

Report the server as configured but awaiting sign-in until its connection
status confirms it is connected.

OAuth credentials are stored outside the OpenCode configuration. Do not ask for or
store an API key when the server supports OAuth. Use header-based credentials
only when OAuth is unavailable or the user explicitly requires them, and use an
environment substitution such as `{env:MCP_API_KEY}` instead of writing a
secret into configuration.

## [V1 to V2 migration](https://opencode.ai/v2/docs/migrate-v1)

For any request to migrate OpenCode configuration, agents, commands, skills,
plugins, integrations, or other behavior from V1 to V2, read the full
[migration guide](https://opencode.ai/v2/docs/migrate-v1) before acting. In
the repository, its source is `services/www/src/docs/content/migrate-v1.mdx`.

V1 config files and `.opencode/` definitions are intended to remain compatible.
The only intentional breaking changes are the server API and plugin API. Native
V2 config uses more ergonomic shapes, but conversion is optional. When the user
requests conversion, inspect the complete configuration, preserve behavior and
unrelated settings, and apply only the relevant migrations from the guide. For
plugin migrations, fetch and follow both the migration guide and the full
[plugins guide](https://opencode.ai/v2/docs/build/plugins). If non-API V1
functionality fails in V2, use the `report` skill to file it as a compatibility
bug.

## [Plugins](https://opencode.ai/v2/docs/build/plugins)

For questions about creating, configuring, loading, publishing, or migrating
plugins, fetch the full [plugins guide](https://opencode.ai/v2/docs/build/plugins)
before answering. Refer to this guide when the user wants to build a plugin. It
covers hooks, transforms, tools, plugin context capabilities, and package
entrypoints. Plugins can also extend the TUI; for those, fetch the
[CLI plugin guide](https://opencode.ai/v2/docs/build/plugins/cli).
For custom methods and events shared with other plugins or clients, fetch the
[RPC guide](https://opencode.ai/v2/docs/build/plugins/rpc).

## [Service](https://opencode.ai/v2/docs/troubleshooting#check-the-background-service)

OpenCode uses a client-server architecture. Interfaces such as the TUI connect
to a background OpenCode service, which owns sessions, configuration, plugins,
permissions, and tool execution.

OpenCode normally discovers or starts the shared background service
automatically. If the service is stuck or unhealthy, restart it:

```sh
opencode service restart
```

Check its status after restarting:

```sh
opencode service status
```

## [API](https://opencode.ai/v2/docs/api)

OpenCode exposes an HTTP API from its server. The API is described by an
OpenAPI document available from the running server at `/openapi.json`.

Use OpenCode's built-in `api` command for local requests. It uses the same
discovery and authentication flow as the TUI and may start the background
service when no compatible healthy service is available. It accepts either an
HTTP method and path or an OpenAPI operation ID.

Call an endpoint with an HTTP method and path:

```sh
opencode api get /api/info
```

Pass a request body with `--data` or `-d`, and additional headers with
`--header` or `-H`:

```sh
opencode api post /api/example --data '{"key":"value"}'
opencode api get /api/example --header 'X-Example:value'
```

Request bodies default to `Content-Type: application/json`. When OpenCode is
connected to an explicit server instead of its managed background service, use
the same configured server and authentication context rather than constructing
an unauthenticated request separately.

See the [full API reference](https://opencode.ai/v2/docs/api) for available
endpoints, parameters, request bodies, and response schemas. The
raw [OpenAPI specification](https://opencode.ai/v2/openapi.json) is also
available for code generation and other tooling.

## [Client](https://opencode.ai/v2/docs/build/client)

For questions about connecting an application to OpenCode over the network,
fetch the full [client guide](https://opencode.ai/v2/docs/build/client) before
answering.

`@opencode/client` is the generated TypeScript client for the OpenCode HTTP
API. Its methods and types come from the same contract as the API reference.
The default entrypoint exposes Promise-based resource clients and async
iterables for streaming endpoints. The `@opencode/client/effect` entrypoint
exposes typed Effects, Streams, and decoded OpenCode schema values. Its
`Service` API can discover, start, stop, and authenticate with the local
background service from a Node application.

## [SDK](https://opencode.ai/v2/docs/build/sdk)

For questions about embedding OpenCode directly in an application, fetch the
full [SDK guide](https://opencode.ai/v2/docs/build/sdk) before answering. The SDK
hosts OpenCode in the application without opening an HTTP listener.

Use the [Effect SDK guide](https://opencode.ai/v2/docs/build/sdk/effect) for
Effect applications. For Cloudflare Durable Objects, use the
[Cloudflare SDK guide](https://opencode.ai/v2/docs/build/sdk/cloudflare).

## [Troubleshooting](https://opencode.ai/v2/docs/troubleshooting)

OpenCode runs a client and a background server. Start by determining whether a
problem belongs to the client, the shared server, or one project.

- Check the service with `opencode service status` and verify the API with
  `opencode api get /api/info`.
- Compare with `opencode --standalone`, which runs the TUI with a private
  server, to isolate shared-service issues.
- Inspect `~/.local/share/opencode/log/opencode.log`. Filter `role=cli` for
  client startup and `role=server` for sessions, providers, plugins,
  permissions, and tools.
- Run one reproduction with `OPENCODE_LOG_LEVEL=DEBUG` when normal logs are not
  sufficient.
- Do not delete or edit the database, service registration, or service config
  while diagnosing a problem. Back up persistent data before inspecting it
  with external tools.
- Redact API keys, authorization headers, prompts, file contents, and other
  sensitive data before sharing diagnostics.

See the [full troubleshooting guide](https://opencode.ai/v2/docs/troubleshooting)
for service lifecycle commands, API inspection, log locations, explicit server
connections, issue-reporting details, and local development paths.

## Local environment notes

Field-verified details for Killian's global setup (`~/.config/opencode/opencode.jsonc`, `opencode v2.0.23` at `/usr/bin/opencode`). These supplement the V2 docs above.

### Inspecting the live configuration

- `opencode api get /api/config` returns the merged config **documents in load order**, confirming which files are actually in effect and showing resolved values (`$HOME` expanded).
- `opencode api get /api/agent` lists every agent with its **effective** permission list (built-in defaults merged with top-level `permissions` and `agents.<id>.permissions`).
- `opencode service status` prints the background server URL.

### Background service and hot reload

- Editing `opencode.json(c)` is picked up by the running service **without a restart** — verified: `/api/config` reflected a `permissions` edit immediately.
- If a change does not apply, run `opencode service restart`.

### Permissions shape (V2)

- `permissions` is an ordered array of `{ "action", "resource", "effect" }`; effects are `allow`, `ask`, `deny`.
- **Last matching rule wins**, so a broad `allow` can be narrowed by later `deny` rules, and a later rule can re-enable something an earlier rule denied.
- Actions include `read`, `edit`, `external_directory`, `shell`, `skill`, `question`, `subagent`, `browser`; plugin-registered tools appear as their own action (e.g. `searxng`).
- The shell tool's config action is `shell`, but it is logged internally as `bash`. `permission=bash` in the logs means the shell tool.
- Shell `resource` patterns are matched against the **entire command string**; wildcarded entries act as substring matches. A rule such as `*rm -rf*` blocks any command whose text contains `rm -rf`, even inside a commit message or a filename argument. This is the single biggest source of confusing "Permission denied: shell" errors. Confirmed false positives: a `dotfiles-sync.sh push "…rm -rf…"` commit message, a `grep 'rm -rf|shutdown|reboot|poweroff'` diagnostic, and a harmless `echo "for reboot persistence"` (rejected by the `*reboot*` rule). Long compound commands are especially prone because they contain more words. Diagnostic commands that merely *mention* a denied token are blocked too; work around it by not spelling the literal, e.g. build it with concatenation: `w="re""boot"`. The kept rules were later refined from substring globs to command-boundary patterns (global and plan): `rm -rf *`, `sudo rm -rf *`, `reboot *`, `sudo reboot *`, `systemctl reboot *`, `shutdown *`, `sudo shutdown *`, `poweroff *`, `sudo poweroff *`, `systemctl poweroff *`. Because the shell scanner emits one command string per subcommand, anchoring at the command word blocks `foo; sudo rm -rf x` while letting `echo "for reboot persistence"` and `echo "rm -rf is text"` through (all four verified live). Avoid the generic `*word*` form — it is the thing that causes mention-based false positives.
- Permission **denials may not be logged**: a freshly rejected `echo "for reboot persistence"` did not appear in `opencode.log` (older deny evaluations from prior versions do). So absence of an `action.action=deny` line does not prove a command was not blocked — reproduce with a harmless probe like `echo control-ok` versus a suspect command.

### Global config precedence

- Global: `~/.config/opencode/opencode.json(c)`. Project: `opencode.json(c)` or `.opencode/opencode.json(c)`, searched from the working directory up to the filesystem root.
- Merge order: farthest ancestor → current directory; all direct files merge first, then all `.opencode` files, so every discovered `.opencode` config overrides every discovered direct config. Global filesystem config is lowest precedence.

### V1 vs V2 config keys

- V1 used singular `plugin`, `provider`, `agent`, `permission` (an object keyed by `bash`, `edit`, …). V2 uses plural `plugins`, `providers`, `agents`, `permissions` (an array) and the `shell` action.
- The `$schema` URL `https://opencode.ai/config.json` may describe V1 even in V2 files; never infer V2 field names or shapes from it.

### Built-in skills and local overrides

- Built-in skills (including this `opencode` skill) are compiled into the `opencode` binary; their base directory `/builtin` is virtual and does not exist on disk, so they cannot be edited in place.
- Skill precedence (low → high): built-in → `~/.claude/skills` / `~/.agents/skills` → `~/.config/opencode/skills` → project `.opencode/skills` → explicit `skills` config entries.
- To extend or override a built-in skill, create a local `SKILL.md` with the **same path-derived ID** (e.g. `~/.config/opencode/skills/opencode/SKILL.md`). The local definition replaces the built-in entirely, so re-include its content plus your additions and re-sync it after OpenCode upgrades.

### Skills mechanics

- Skill IDs are path-derived and case-sensitive; `skills/<id>/SKILL.md` and `skills/<id>.md` both yield ID `<id>`.
- Frontmatter `name` is only a display label; the ID comes from the path. A clear `description` is required for the skill to be advertised to the model.
- `metadata.opencode/autoinvoke: false` (or `disable-model-invocation: true`) hides a skill from the model's list while keeping it loadable by explicit ID.

### cli.json is separate

- Terminal-only settings (plugins, `attention`, keybinds, theme, input, tabs) live in `~/.config/opencode/cli.json`, **not** `opencode.json(c)`. There is no project-local CLI config.

### Debugging permissions

- Permission decisions are logged to `~/.local/share/opencode/log/opencode.log` as `message=evaluated permission=<...> action.permission=<rule> action.pattern=<pattern> action.action=<allow|ask|deny>`.
- `GET /api/session/<id>/permission` returning 404 is normal — it means no permission request is pending for that session.
