# telegram-claude Agent Guide

## What This Skill Is For

Use `telegram-claude` when a Claude session needs to communicate through Telegram while keeping Dashboard in control of the polling lifecycle.

This skill gives Claude:

- Telegram update polling
- inbound text, photo, video, audio, voice, and document metadata
- Telegram file download by `file_id`
- outbound text reply
- outbound photo send
- outbound audio send
- outbound document send
- managed two-way Telegram communication through one DD collector per active workspace session

## Runtime Model

The always-on path is no longer a separate ad hoc listener command.

The managed path is:

```bash
dashboard telegram-claude.start
```

That command:

1. keeps the saved-session mapping logic from `TICKET_REF` and `~/.developer-dashboard/config/claude.json`
2. derives a collector session id from:
   - `TELEGRAM_CLAUDE_SESSION_ID`
   - otherwise the workspace directory name
3. ensures there is exactly one collector named `telegram-claude-<session-id>` in `~/.developer-dashboard/config/config.json`
4. removes duplicates for that collector name and heals stale same-workspace `telegram-claude-*` entries that still point at the wrong session id
5. writes the actual Claude resume target into:

```bash
~/.telegram-claude/<session-id>/claude.session
```

6. restarts:

```bash
dashboard restart collector telegram-claude-<session-id>
```

7. recycles any already-running `check-message <session-id>` worker for that same session so stale long-lived code does not stay active
8. prunes stale orphaned duplicate `claude --resume <session-id>` processes for the mapped reply session before polling begins
9. launches the real Claude binary with `--dangerously-skip-permissions`

`dashboard telegram-claude.start --version` is a safe metadata query for DD probe/discovery paths, must not create or restart collectors, and proxies the real `claude --version` output the DD launcher expects.
Successful managed startup now hands off with `exec`, so the wrapper process should not remain as an extra long-lived `cli/start` parent once Claude is running. The managed start argv also prepends `--dangerously-skip-permissions` before the real Claude handoff so direct Telegram-owned startup keeps the same non-interactive execution contract as managed resumed reply subprocesses. Ambient workspace `OLLAMA_MODEL` is intentionally ignored here; use `TELEGRAM_CLAUDE_OLLAMA_MODEL` only when Telegram-managed startup should explicitly inject the Ollama model via `--model`.
If the managed reply path is cutting off mid-operation, use:

```bash
dashboard telegram-claude.start --audit
```

That enables per-session audit rows under `~/.telegram-claude/<session-id>/audit.jsonl`.
Because managed startup now recycles the old per-session worker first, `--audit` and newer progress behavior take effect immediately instead of being hidden behind a stale long-lived loop.

When `~/.telegram-claude/<session-id>/claude.session` exists, the collector-owned `dashboard telegram-claude.check-message <session-id>` worker automatically resumes that Claude session to generate the Telegram reply text.
If that file is missing, the managed reply path falls back to the saved-session mapping in `~/.developer-dashboard/config/claude.json`.
When the target session exists, managed replies also hydrate from recent persisted rows in that Claude session transcript and then append readable Telegram user and assistant turns back into the same transcript so later resumed TUI work sees the shared persisted history too.
If the mapped Claude session is already open in a tmux-backed TUI and the live `claude --resume <session-id>` process can be matched back to a tmux pane, managed Telegram work is injected into that same live pane instead of always running beside it in detached resume mode. Live-pane selection prefers the freshest matching tmux-backed `claude --resume <session-id>` process instead of the first stale match. If the injected Telegram turn never appears in the live transcript, the worker fails fast, audits the reason, and falls back to detached resume. TUI-originated turns are mirrored back to Telegram from the same transcript stream, and that mirror path now keeps Telegram `typing...` active until the final outbound Telegram reply send completes even when the final assistant turn lands in a later collector poll.

## Collector Contract

The collector shape is:

```json
{
  "name": "telegram-claude-<session-id>",
  "interval": 5,
  "rotation": { "lines": 100 },
  "cwd": "<workspace where start was run>",
  "command": "dashboard telegram-claude.check-message <session-id>",
  "mode": "singleton"
}
```

`dashboard telegram-claude.check-message <session-id>` is a long-running polling loop. Dashboard may try to start it every five seconds, but singleton mode plus the same-session pid guard prevents overlap while the active loop is still running. When `claude.session` exists for that session, the worker replies through that persisted Claude session automatically. If that file is missing, the worker falls back to the saved-session mapping in `~/.developer-dashboard/config/claude.json`. If `listener.inbox.jsonl` proves a newer next offset than `listener.offset`, the worker rewrites `listener.offset` before polling so restart state stays accurate. Before the polling loop continues, the worker also prunes stale orphaned duplicate `claude --resume <session-id>` processes that are older than the freshest live tmux-backed owner on the same tty. While a managed Claude reply is being processed, the worker keeps Telegram `typing...` status active until the final outbound Telegram send attempt completes. Instead of a placeholder heartbeat, the worker now streams real `claude -p --resume <session-id> --output-format stream-json --verbose` agent and command events into one Telegram verbose trace message that stays visible in chat. Managed Claude-session replies now open that trace by default, including short conversational follow-up messages, and still emit an immediate kickoff line before richer Claude JSON events arrive. Before that managed reply path is allowed, the session must be paired: the first unpaired Telegram message gets a single local `d2 telegram-claude.pair <hexcode>` reply, later unpaired messages are ignored, and after the local pair command succeeds only that paired chat can drive the session. The session audit records explicit pairing decisions as `pairing.challenge.sent`, `pairing.ignored`, and `pairing.allowed` before managed Claude reply work starts. Supported inbound media is downloaded into the session runtime before Claude replies. Downloaded Telegram photos and image documents are referenced by local path in the reply prompt so Claude opens them with its Read tool; other downloaded media remains local-path-only for tool-based inspection. Claude can return attachment directives to send photos, audio, or documents back to Telegram. When the mapped session is already live in a tmux-backed Claude TUI, the worker prefers the freshest matching live pane and transcript tailing before it falls back to detached resume. If the injected Telegram turn never appears in the live transcript, the worker fails fast, audits the reason, and retries through detached resume instead of leaving the chat stuck on the kickoff line.
The first unpaired trigger message now stops at the pairing gate completely: it does not resume Claude, does not inject into the live TUI, and does not append to the shared Claude transcript.
For paired chats, supported Telegram slash commands are handled directly by `telegram-claude` before the managed Claude reply path. Today the supported direct Telegram slash commands are `/help` and `/status`. Surrounding whitespace or newline noise is stripped before slash parsing so padded Telegram slash commands still stay on the direct command path instead of being forwarded into Claude as ordinary prompt text. Unsupported Telegram slash commands are rejected explicitly instead of being forwarded into Claude as ordinary prompt text. When the mapped Claude session is live in a tmux-backed TUI, `/status` should behave as a shared-session command: inject `/status` into the live pane, capture the rendered Claude status panel, and return that panel to Telegram. If no live shared pane exists, return the explicit unavailable message instead of synthesizing a detached local summary.
If a verbose progress edit fails, the worker now records that as a non-fatal progress failure and still attempts the final Telegram reply. If the resumed Claude subprocess exits early or returns an empty reply, the worker now records exit code, signal, stderr tail, and progress events in `audit.jsonl` instead of only surfacing a generic failure.

## What The Skill Can Receive

The skill can receive Telegram update metadata for:

- text
- photos
- video
- audio
- voice
- documents and other files

The polling loop records those inbound updates in:

```bash
~/.telegram-claude/<session-id>/listener.inbox.jsonl
```

Downloaded inbound media for managed replies is stored under:

```bash
~/.telegram-claude/<session-id>/downloads/
```

## What The Skill Can Read Versus Download

This skill reads Telegram update metadata directly.

For actual binary content, download first:

```bash
dashboard telegram-claude.download <FILE_ID>
```

That applies to:

- images
- video
- audio
- voice
- PDFs
- other Telegram-hosted files

The shipped `download` path and the managed collector-owned media reply path both use Telegram Bot API `getFile` query-string parameters correctly, so real Telegram photo and file downloads are expected to work in live runs.

Do not claim a binary attachment was read unless it was downloaded first.
Do not claim any media bytes were attached directly to the model; downloaded Telegram photos and image documents are referenced by local path in the reply prompt so the resumed Claude session opens them with its Read tool. Other media is referenced by local path for tool-based inspection only.

## What The Skill Can Send Back

Text:

```bash
dashboard telegram-claude.reply <CHAT_ID> 'Message received'
```

Photo:

```bash
dashboard telegram-claude.send-photo <CHAT_ID> ~/Pictures/demo.png
```

Audio:

```bash
dashboard telegram-claude.send-audio <CHAT_ID> ~/Music/reply.mp3
```

Document:

```bash
dashboard telegram-claude.send-document <CHAT_ID> ~/Downloads/report.pdf
```

This skill does not currently expose dedicated outbound video sending.

## Key Commands

Install plugin bridge:

```bash
dashboard telegram-claude.install 123456:telegram-bot-token
```

Managed start:

```bash
dashboard telegram-claude.start
```

Collector loop:

```bash
dashboard telegram-claude.check-message <session-id>
```

Inspect updates:

```bash
dashboard telegram-claude.updates
```

Download file:

```bash
dashboard telegram-claude.download <FILE_ID>
```

Managed attachment reply directive:

```text
telegram_attachment_type=photo|audio|document
telegram_attachment_path=/absolute/local/path
telegram_attachment_caption=optional caption
```

## Important Rules For Another Claude Session

- Use `dashboard telegram-claude.start` when Telegram is meant to be the primary communication channel.
- Treat `dashboard telegram-claude.check-message <session-id>` as a collector-owned long-running loop, not as a short one-shot helper.
- Expect one DD collector per workspace session.
- Expect per-session state under `~/.telegram-claude/<session-id>/`.
- Expect true live Telegram/TUI turn sharing only when the mapped Claude session is already open inside tmux and can be matched back to a live `claude --resume <session-id>` process.
- Expect nested managed `claude` calls in the same process tree to skip collector restarts because startup carries a reentry guard.
- Expect `~/.telegram-claude/<session-id>/audit.jsonl` to be the first place to inspect when a managed Telegram task starts, streams progress, then cuts off mid-run.
- Do not claim outbound video sending support.
- Do not claim binary attachment content was inspected unless it was downloaded first.
- Do expect the managed Telegram path to keep a readable verbose step trace in chat from real `claude -p --resume <session-id> --output-format stream-json --verbose` events instead of a placeholder progress heartbeat.
- Do expect task-style Telegram replies to answer directly without boilerplate prefaces and to do the actual in-session work before sending the final reply.
