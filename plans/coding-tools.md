# Coding tools: make a coding CLI a thing you declare, not a thing you wire

## Context

Getting opencode working inside OpenBot took a full day. Almost none of that was opencode's
fault — it was discovering, one failure at a time, a set of facts nobody had written down:
that the shell strips the environment unless a variable is allow-listed; that `HOME` is the
workspace, not `/root`; that opencode hangs forever without `< /dev/null`; that a run taking
longer than the stall timeout kills the turn; that the per-Bot computer the supervisor spawns
is a different container from the one `compose.override.yml` configures.

The result works, but it lives in five untracked config files and one Postgres row. Anyone
cloning the repo and wanting Claude Code or pi instead would rediscover every one of those
facts from scratch.

The goal: **a coding CLI becomes a manifest you drop in, plus a grant on a Bot.** Three work on
day one — opencode, Claude Code, pi. A fourth should be a YAML file and no code.

Target: this fork, shaped so an upstream PR stays possible.

---

## What already exists — do not reinvent these

Three findings that shape everything below.

**1. "Harness" is taken, and means something else.** `desktop/src-tauri/src/harness.rs` is a
13-row catalogue of *AG-UI agent frameworks* (CrewAI, LangGraph, Claude Agent SDK, Mastra…) —
a Bot's brain, not a coding CLI. Its header is the pattern to imitate:

> *"One list, and every row resolves to the same thing… A row is a manifest rather than a branch
> in wizard code, so adding a harness is an entry here plus an image, and never a new screen."*

It also carries a **tested no-adapters rule** (`harness.rs:915-926`) that explicitly excludes
Codex and Gemini CLI. **Do not add coding CLIs there.** Different layer, and the test would
rightly reject them. New concept, new name: **coding tool**.

**2. The shell has no tool registry, and that is deliberate.** `computer_run_command` →
`/exec` → `agent-computer/src/shell.ts`. Anything on `PATH` is callable; nothing declares
itself. `COMPUTER_SHELL_ENV` is an env-var allowlist only (`shell.ts:48-63`). `shell.ts:12-14`
draws the line we must respect:

> *"WHAT MAKES IT SAFE IS NOT THIS FILE. Nothing here decides whether a command may run. The
> gateway decides… This file is the hands, not the judgement."*

**3. A surface tool ends the run before the browser executes it.** `agent-langgraph/src/index.ts:371-383`
returns `END` when the model calls a tool the surface owns. `callComputer`
(`app/src/lib/copilot/computer-tools.tsx:52`) has no timeout of its own — only the user's Stop
signal. **So a tool handler may run for minutes.** The stall guard has already stopped ticking.

That last point is the design's foundation and the biggest single win: the launch-and-poll loop
we taught the Dev Agent belongs *in the tool handler*, where the model never sees it.

---

## The design

### 1. A manifest per coding tool — `coding-tools/*.yaml`

Data files in the repo, loaded and schema-validated at server start. Adding a tool is a file.

```yaml
id: opencode
name: opencode
summary: Minimal terminal coding harness. Reads, searches and edits a repo.
install: curl -fsSL https://opencode.ai/install | bash   # build time only, never at runtime
binary: opencode
credential:
  env: AI_GATEWAY_API_KEY          # composed into COMPUTER_SHELL_ENV automatically
invoke:
  argv: ["opencode", "run", "{task}"]
  stdin: /dev/null                  # the hang we lost an hour to
  env: { NO_COLOR: "1" }
  cwd: "{repo}"
done_when: process_exits
```

Plus `claude-code.yaml` and `pi.yaml`. Two rules the schema enforces:

- **`install` runs at image build only.** Never from a request. A manifest cannot cause a
  download at runtime.
- **`{task}` is an argv element, never string-concatenated into a shell line.** Today the role
  description tells the model to build a shell string with the task inside it; that is a command
  injection waiting for a task containing a backtick.

### 2. Per-Bot selection reuses `plugin_grants`

No new table. `plugin_grants` is already `(kind, ref, agent_id)` with audit and a per-Bot grant
UI. A row of `("coding-tool", "opencode", "agent_abc…")` says this Bot may use opencode.

*Verify during implementation* whether the plugin store filters `kind` on read
(`server/src/plugins/store.ts:645-673` reads `kind = "mcp"` in places) — if it does, widen it
rather than adding a table.

### 3. One frontend tool, driven by the manifest

Add **one** tool to `app/src/lib/copilot/computer-tools.tsx` — the file is 14 literal
`useFrontendTool` calls, so this is one core edit and then every future coding tool is a YAML
file. The handler does what we taught the Dev Agent to do by hand:

1. resolve the Bot's granted coding tool from the registry
2. render the manifest's argv with the task as one argument
3. launch detached, redirected to a log
4. **poll `/exec` on a short interval until the process exits**
5. return the transcript

The model calls `coding_agent_run({ task, repo })` once and gets a result. It never learns
`< /dev/null`, `nohup`, `NO_COLOR`, or the polling loop — all of which are currently prose in a
database row that no git history will ever show you.

Use the `render` callback to show live progress, the way the existing computer tools do.

### 4. `COMPUTER_SHELL_ENV` composed, not hand-written

The single worst papercut. Today an operator must know that `shell.ts` strips the environment
and that naming the variable is the opt-in. Instead: compose the allowlist from the
`credential.env` of every installed manifest, and pass it in `docker-compose.yml`. Keep the
manual override working — an operator naming `GITHUB_TOKEN` still means it.

### 5. Image build driven by the same manifests

Replace the ad-hoc `agent-computer/Dockerfile.opencode` with a build arg naming which tools to
bake in, each contributing its `install` line. One image, N tools, no per-tool Dockerfile.

Note `Dockerfile:205-208` — only `/workspace` survives a restart, so a runtime `apt-get install`
is not durable. Baking at build time is the correct answer, not a shortcut.

### 6. Docs

`docs/coding-tools.md`: what a coding tool is, how it differs from a *harness* (say this
explicitly — the words will collide otherwise), the manifest reference, and the six failures
from the opencode integration as a troubleshooting section. `docs/development.md` currently says
nothing about adding agents or harnesses; this is the hole to fill.

---

## Files

| File | Change |
|---|---|
| `coding-tools/{opencode,claude-code,pi}.yaml` | new — the manifests |
| `server/src/coding-tools/manifest.ts` | new — type, loader, schema validation |
| `server/src/coding-tools/routes.ts` | new — list installed tools; resolve a Bot's tool |
| `server/src/plugins/store.ts` | widen grant reads to the `coding-tool` kind if needed |
| `app/src/lib/copilot/computer-tools.tsx` | one new `useFrontendTool` (launch, poll, return) |
| `agent-computer/Dockerfile` | build arg + manifest-driven installs |
| `agent-computer/Dockerfile.opencode` | delete — superseded |
| `docker-compose.yml` | composed `COMPUTER_SHELL_ENV`, build arg |
| `docs/coding-tools.md` | new |

Follow `server/src/plugins/catalogue.ts` for house style: explain *why* in the comment, name the
failure the rule prevents.

---

## Explicitly out of scope

- **Wrapping a coding CLI as an AG-UI Bot.** A different shape; `harness.rs` owns that layer.
- **Unattended use.** `computer_run_command` is a frontend tool, so a coding tool needs a browser.
  Routines cannot use one. Say so in the docs rather than discovering it later.
- **A runtime "add a coding tool" API.** The MCP custom-server route
  (`POST /api/plugins/servers/custom`) is the precedent if this is wanted later. For a fork,
  editing a YAML file is the expected act.

---

## Verification

1. **Manifest schema** — unit tests: a manifest missing `binary` is refused; `{task}` stays one
   argv element when the task contains backticks, quotes and newlines; an `install` key cannot be
   reached from a request path.
2. **Grant resolution** — a Bot with no coding-tool grant is not offered the tool; a Bot with two
   grants is refused rather than guessing.
3. **The long-run property** — the thing this design rests on. A task that takes longer than
   `AGENT_STALL_TIMEOUT_MS` must complete and return, proving the handler outlives the run. Test
   against a manifest whose invoke is `sleep 200 && echo done`.
4. **End to end, all three** — same task through opencode, Claude Code and pi in one Bot each,
   against a real repo under `/workspace/projects`. This is the real test of whether the
   abstraction generalises; pi is the odd one out and the most informative.
5. **Regression** — full server suite against a pristine `origin/main` worktree on the same
   database, as with the last branch. Baseline parity, not an absolute number.
6. **The papercut check** — a fresh clone, one manifest, one grant, and a working coding tool
   with nobody editing `COMPUTER_SHELL_ENV` or a role description by hand. If that does not hold,
   the design has not done its job.
