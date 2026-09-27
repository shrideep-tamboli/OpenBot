# Plans

Planned additions and fixes for this fork, one document per change. A plan lands here **before**
the work starts, and is deleted or marked shipped once it has.

Each one states its context, what already exists that must not be reinvented, the design, the
files it touches, what is explicitly out of scope, and how it will be verified. The out-of-scope
and verification sections are the two that earn their keep — they are what a plan is for.

| Plan | What it is | Target |
|---|---|---|
| [coding-tools.md](coding-tools.md) | Make a coding CLI a manifest you drop in, not five untracked config files | This fork, shaped for an upstream PR |
| [mcp-image-content.md](mcp-image-content.md) | Let a model see an image an MCP tool returned, instead of the string `[image]` | Beacon (small) + upstream OpenBot (real work) |
| [local-models.md](local-models.md) | `./run-openbot.sh --local`: every model call on this Mac. Where it stands and the to-do list to resume from | This fork, branch `feat/local-models` |
