# 2026-06-11 — Initial Claude Code bridge (DD-383)

Initial release of `telegram-claude`, replicating the `telegram-codex` Telegram
bridge runtime against the Claude Code CLI (`claude`).

## What changed versus telegram-codex

- **Module/CLI namespace:** `lib/Telegram/Claude/Manager.pm`, CLI surface
  `dashboard telegram-claude.*`, runtime state under `~/.telegram-claude/`.
- **Managed reply contract:** replies resume the saved Claude session with
  `claude -p "<prompt>" --resume <session-id> --output-format stream-json
  --verbose --dangerously-skip-permissions`. The final reply text comes from the
  `{"type":"result"}` stream-json event rather than an output-capture file.
- **Verbose trace rendering:** Claude stream-json events are mapped to in-chat
  trace lines — `system`/`init` → `Session resumed`, assistant `text` →
  `Agent: ...`, assistant `tool_use` → `Running tool: <name>: <detail>`, user
  `tool_result` (string or array content) → `Output: ...`, `result` →
  `Turn completed`.
- **Live tmux sharing:** discovery matches `claude --resume <session-id>`
  process command lines; the shared transcript is the Claude Code JSONL at
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, with rows shaped
  `{ "type": "user"|"assistant", "message": { "role", "content": [ { "type":
  "text", "text" } ] } }`.
- **Image handling:** downloaded photos and image documents are referenced by
  local path in the reply prompt (`telegram_image_local_path=...`) so Claude
  opens them with its Read tool; there is no `-i` binary-attach flag.
- **Startup flags:** managed startup prepends `--dangerously-skip-permissions`;
  explicit Telegram-owned Ollama startup injects `--model <model>`.
- **Version probe:** `dashboard telegram-claude.start --version` proxies the
  real `claude --version` output without collector side effects.
- **E2E lab:** the Docker noVNC lab installs `@anthropic-ai/claude-code` and
  launches the visible Claude terminal with `--dangerously-skip-permissions`.

## Verification

- Docker functional gate: `Files=7, Tests=893`, `Result: PASS`.
- Docker covered gate: `lib/Telegram/Claude/Manager.pm` statement `100.0`,
  subroutine `100.0`; `cover_db` cleaned via a disposable container.
- Evidence recorded in `tickets/TESTING.md`.
