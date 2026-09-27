# MCP images: let a model see the screenshot a tool returned

## Context

BEA-216 ("ID reflected in Connection Cards") was filed with **no written description at all** —
its entire body is one attachment, `Screenshot 2026-09-19 at 10.56.25 AM.png`. A Dev Agent asked
to fix it read the five-word title, matched "connection card" and "ID" against the repo it was
already sitting in, and fixed OpenBot's *connected-account* cards. The real bug was in a different
product entirely (`aireadyschool`, `components/connection-card-viewer.tsx:173`, where a card's raw
`id` renders as a visible badge).

It did not hallucinate. It guessed, because guessing was the only thing available: **the one piece
of evidence that would have disambiguated the ticket never reached the model.**

This is not specific to Beacon. Any tracker, any Notion page, any MCP tool that answers with an
image hits the same wall. As issue trackers and doc tools move to MCP, "the screenshot is the
ticket" becomes the common case rather than the exception.

Target: this fork for gap A, an upstream PR for gap B.

---

## Two independent gaps

Both must close. Fixing either one alone changes nothing observable.

### Gap A — Beacon returns a relative URL inside a text blob

`get_work_item` answers with the description as literal markdown text:

```
![Screenshot 2026-09-19 at 10.56.25 AM.png](/api/attachments/lN9lU0XWkmXp_a-1lQ9BF)
```

Two problems in one line. It is **not** an MCP image content block, so no client could treat it as
an image. And the URL is **relative** — no scheme, no host — so nothing downstream could fetch it
even if it wanted to. A model reading this learns only that an attachment exists and that it is
called "Screenshot".

### Gap B — OpenBot flattens every result to a string

`server/src/plugins/mcp.ts:72-75`, inside `resultText`:

```ts
// A non-text part is named rather than dropped. A model told "[image]" can say the tool
// returned an image; a model handed nothing concludes the tool returned nothing.
return `[${item.type ?? "unknown"}]`;
```

An `image` content block becomes the five-character string `[image]`. The bytes are discarded one
function call after arriving.

This is not an oversight, and the comment above it is right on its own terms: naming the part beats
silently dropping it, because a model handed nothing invents. But "name it" was the whole ambition,
and it is no longer enough.

The narrowing is structural, not local. Four points in the chain are typed as `string`:

| Point | Shape |
|---|---|
| `resultText()` — `mcp.ts:47` | returns `{ text: string, truncated: boolean }` |
| `McpCallResult` — `mcp.ts:365-371` | `{ text: string, isError, truncated }` |
| `callTool()` — `mcp.ts:381` | resolves to `McpCallResult` |
| `vendorAnswer()` — `plugins/tools.ts:53-56` | returns a `string` to the model |

So there is no channel for bytes to travel down. Widening one link accomplishes nothing.

---

## This is upstream, not our fork

Worth stating plainly, because it decides where the work goes:

```
$ git diff --stat upstream/main -- server/src/plugins/mcp.ts
(empty)
```

`server/src/plugins/mcp.ts` is byte-identical to `upstream/main`. Every OpenBot deployment drops
MCP images; our Beacon integration did not cause it and cannot fix it locally without diverging.

Gap A is ours and small. Gap B is upstream and real work.

---

## The design

### 1. `resultText` gains a sibling, and does not change

Leave `resultText` exactly as it is — it has tests, and its empty-result reasoning is load-bearing
for the knowledge-connector slice. Add `resultParts(content, structuredContent)` beside it,
returning an ordered array:

```ts
type ResultPart =
  | { type: "text"; text: string }
  | { type: "image"; mimeType: string; data: string };  // base64, as MCP sends it

type McpCallResult = {
  text: string;        // unchanged — still the flattened form
  parts?: ResultPart[]; // present only when a non-text part survived
  isError: boolean;
  truncated: boolean;
};
```

`text` staying authoritative is the point: every existing caller keeps working untouched, and
`parts` is additive. `gmail-imap.ts:192-204` constructs `McpCallResult` by hand and needs no edit.

### 2. Only the model-facing path reads `parts`

`vendorAnswer` (`plugins/tools.ts:53`) is the single place a result becomes what a model reads.
It returns multimodal content when `parts` carries an image, and a plain string otherwise. The
HTTP routes (`app.ts:1398`, `plugins/routes.ts:2515`) keep reading `.text` and are not touched.

### 3. Budget images like attachments, not like text

`MAX_RESULT_CHARS` (20,000) is a character budget and means nothing for base64. Images need their
own ceiling, and the repo already has the machinery: `channels/attachment-parts.ts` has
`newInlineBudget` and `resolveAttachmentParts` for exactly this problem on the human-upload path.
**Reuse it rather than inventing a second budget.** A result carrying six screenshots must degrade
to `[image: over budget]` rather than blowing the context window.

### 4. A vision check, and an honest failure

If the configured model cannot see images, dropping to `[image]` is correct — but it must say why.
`[image: this model cannot read images]` is the difference between a model that reports a limit and
a model that quietly guesses, which is the failure that started this document.

### 5. Gap A, separately and first

Beacon returns an absolute URL, and ideally an image content block. This is small, independent, and
testable on its own. It also makes gap B demonstrable — without it there is nothing to test against.

---

## Files

| File | Change |
|---|---|
| `server/src/plugins/mcp.ts` | new `resultParts`; `McpCallResult.parts`; populate in `callTool` |
| `server/src/plugins/tools.ts` | `vendorAnswer` returns multimodal when `parts` has an image |
| `server/src/channels/attachment-parts.ts` | reuse the inline budget for tool-returned images |
| `server/tests/mcp-result.test.ts` | extend — existing cases must pass unchanged |
| `docs/` | what a connector must return for an image to reach a model |
| *(Beacon, separate repo)* | absolute attachment URL + MCP image content block |

Follow `server/src/plugins/catalogue.ts` for house style: explain *why*, name the failure the rule
prevents. `mcp.ts` is unusually well-commented; match it.

---

## Explicitly out of scope

- **Fetching images from URLs a tool mentions.** Only content blocks the server actually returned.
  Following arbitrary URLs from tool output is an SSRF surface, not a feature.
- **Audio and video blocks.** Same mechanism, no demand yet. `parts` leaves room.
- **Sending images back *to* an MCP tool.** Different direction, different problem.
- **Vision for the opencode path.** opencode has its own config and its own model pinned in
  `agent-computer/opencode.json`; it is not reached by this chain at all.

---

## Verification

1. **Nothing regresses** — `server/tests/mcp-result.test.ts` passes untouched. `text` is unchanged
   for every existing input, including the empty-content and `structuredContent` cases.
2. **An image survives** — a stub MCP server returning `{type: "image", data, mimeType}` produces
   a `parts` entry with the bytes intact, and `text` still reads `[image]`.
3. **The budget holds** — a result with many large images degrades rather than blowing the context
   window; assert the ceiling, not a byte count.
4. **A blind model is honest** — configured without vision, the result names the limitation in
   words rather than falling back to a bare `[image]`.
5. **End to end, the real case** — BEA-216 through Beacon MCP, screenshot visible to the model.
   The whole point: an agent given that ticket should be able to say which product it is about.
6. **Upstream parity** — full server suite against a pristine `upstream/main` worktree on the same
   database. Baseline parity, not an absolute number.

---

## Open questions

- Does the Dev Agent's configured model support vision? Decides whether 4 is a live path or a guard.
- Does Beacon's MCP server control its own content blocks, or is the markdown description passed
  through from storage? Changes gap A from small to medium.
- Is `parts` the right name next to `content` (MCP's word) and `text`? Upstream may prefer `content`.
