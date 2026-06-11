# SOW

## `SOW-383`

Package a new `telegram-claude` skill that replicates the `telegram-codex`
Telegram bridge runtime but drives the Claude Code CLI (`claude`) instead of the
Codex CLI. The skill keeps the Developer Dashboard collector-owned polling
model, single-owner `getUpdates` per bot token, token-scoped shared poll roots,
pairing security, live tmux session sharing, inbound/outbound media handling,
per-session audit trail, and the Docker noVNC E2E lab — but every place that
spoke the Codex CLI contract now speaks the Claude Code CLI contract.

In scope:

- isolated `skills/telegram-claude` mini project with its own git repository,
  `.env` (`VERSION=x.xx`), MIT `LICENSE`, `Changes`, `README.md`, `docs/`, `t/`,
  and `tickets/`
- `lib/Telegram/Claude/Manager.pm` runtime and `dashboard telegram-claude.*`
  CLI surface mirroring the `telegram-codex` command set
- managed Telegram replies that resume the saved Claude session through
  `claude -p --resume <session-id> --output-format stream-json --verbose
  --dangerously-skip-permissions` and stream Claude stream-json events into one
  in-place Telegram verbose trace
- live tmux sharing against `claude --resume <session-id>` processes and the
  Claude Code transcript JSONL at
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
- inbound media downloaded into the session runtime, with downloaded photos and
  image documents referenced by local path in the prompt for the Claude Read
  tool
- `dashboard telegram-claude.start --version` proxying the real
  `claude --version` output without collector side effects
- per-session runtime state under `~/.telegram-claude/<session-id>/` and
  token-scoped shared poll roots under
  `~/.telegram-claude/.shared/<sha1(bot-token)>/`
- a Docker noVNC E2E lab that installs the Claude Code CLI
  (`@anthropic-ai/claude-code`)

Out of scope:

- changing the upstream `telegram-codex` skill
- non-Claude provider integrations
- the standing simulator E2E run itself (performed after push per the workspace
  E2E rule), which is a verification activity rather than a deliverable
