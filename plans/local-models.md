# Local models (`./run-openbot.sh --local`): where it stands and what is left

Branch `feat/local-models`, uncommitted. Last worked on 2026-09-28.

## Shipped on the branch

- `./run-openbot.sh --local` sends every model call to Ollama on this Mac: built-in Bots, router,
  tool selection, titles, `agent-langgraph`, `agent-bot`, and opencode on the computer. `.env` is
  untouched; the overrides are exported for the run. Online mode is unchanged (checked against the
  real `.env`: the model is still `openai/gpt-6-luna`, generative UI is still on).
- The server refuses local mode unless `OPENAI_BASE_URL` is on loopback. It never answers through a
  subscription plan and never sends the stored cloud credential there. Built-in Bots use chat
  completions (`runtimeLanguageModel` in `server/src/copilot.ts`).
- `compose.local.yml` takes the gateway key off the computer and mounts
  `agent-computer/opencode.local.json` (provider `ollama`, `host.docker.internal:11434`).
- Ollama is started by the script on loopback, in its own session (a Ctrl-C used to kill it), with
  a 64K context, a q8 KV cache, one model resident and one slot. The log is `.logs/ollama.log`.
  - `status` shows the mode and whether the running Ollama is down, or was not started by the
    script (and so has the wrong context).
  - `./run-openbot.sh ollama` restarts only Ollama.
  - `stop` stops only the Ollama the script started.
- Default model `qwen3.5:4b`. Change it with `OPENBOT_LOCAL_MODEL` for the Bots, and in
  `opencode.local.json` (three places) for opencode.
- `OPENBOT_GENERATIVE_UI=false` in local mode, to drop about 60K characters of A2UI context from
  every request.
- Docs: "Local models" in `docs/configuration.md`, plus a README line.

## Measured on this machine (M5, 16 GB)

| | qwen3.5:9b | qwen3.5:4b |
|---|---|---|
| Resident (`ollama ps`) | 6.8 GB | 4.5 GB |
| Prompt read | ~360 tok/s | ~375 tok/s (no faster; cause unknown) |
| Reply written | ~18 tok/s | ~25 tok/s |

- A General Assistant "hi" is **~51,700 tokens**, which takes about 2 m 20 s before the first word.
- Follow-up turns reuse the cached prefix and take about **4.5 s**.
- In the counter's breakdown, **86 tools make up ~45.7K tokens, and ~50 of those are the Notion
  connector (~37K)**. The system prompt is ~1.8K and the history is tiny.

## To do, in order

1. [ ] **Cut the Notion tools from the General Assistant's prompt.** Pick one:
   - (a) Quick test: ungrant Notion from the General Assistant in Admin, send "hi" and read
     `task.n_tokens` in `.logs/ollama.log`. The target is about 10K tokens.
   - (b) Lasting fix: in local mode, narrow granted tools per message even when no skill declares
     any. The narrowing is `selectTools` in `server/src/plugins/selection.ts:187`; today it is gated
     on a skill declaring tools and on `granted.length > SELECTION_FLOOR`. Weigh the cost of the
     extra selection call against the local model.
2. [ ] **Test opencode through the Dev Agent** (never done):
   - Check the Dev Agent's `type` in the `agents` table. If it is `built_in` it is on qwen.
   - Confirm the computer container reaches `host.docker.internal:11434` from a shell command.
   - Confirm opencode downloads `@ai-sdk/openai-compatible` on its first run.
   - Give it a small scoped edit and confirm it lands, and that `.logs/ollama.log` shows the calls.
   - Watch the 64K limit: opencode compacts at `limit.context`.
3. [ ] **Consider opencode pruning:** add `"compaction": { "auto": true, "prune": true }` to
   `opencode.local.json`, so old tool outputs go before a lossy summary is needed.
4. [ ] **Consider turning thinking off in local mode.** `qwen3.5:4b` thinks by default, and a
   reply's tokens include the thinking. Check whether Ollama's `/v1` endpoint accepts
   `reasoning_effort: "none"` or an equivalent, then measure.
5. [ ] **Check the router and titler under local mode.**
   - The router has a 10 s timeout and the titler 20 s. With one Ollama slot they queue behind a Bot
     turn: two titles already timed out behind a 44K-token turn.
   - They also replace the cached prefix, which makes the next Bot turn slow again. Consider
     skipping titles in local mode, or giving them longer timeouts.
6. [ ] **Find out why 4B reads prompts no faster than 9B.**
   - Check whether llama.cpp's handling of the linear-attention layers is the bottleneck. Try
     `OLLAMA_FLASH_ATTENTION` off and the KV cache type `f16`.
   - Check whether Ollama's MLX engine supports `qwen3.5` yet.
7. [ ] **Remote Bots' stall watchdog** (`AGENT_STALL_TIMEOUT_MS`, 60 s): on a local model a long
   prompt can take longer than that to read, so `agent-langgraph` would be reported as stopped.
   Raise the limit in local mode, or accept it.
8. [ ] **Optional: one place to set the model.** Have opencode follow `OPENBOT_LOCAL_MODEL` too.
9. [ ] **Before the PR:**
   - Run `bun run test`. The 63 failures are the same as on a clean HEAD: Postgres integration tests
     with no database, agent-bot's module resolution, and desktop tests.
   - Lint is clean on the changed files. The only findings are in `.agents/skills/beacon-insights`.
   - Confirm the `qualifiedModelName` change predating this work (`copilot.ts:233`) against the
     gateway. It likely sends bare `gpt-6-luna` online.
   - Open a PR from `feat/local-models`; nothing has been committed.

## Out of scope

Fully offline running. CopilotKit Intelligence (threads, memory) is a required cloud service, and
replacing it is its own project.
