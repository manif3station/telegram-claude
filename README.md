# telegram-claude

## Description

`telegram-claude` is a Developer Dashboard skill that bridges Telegram Bot API into the Claude Code CLI (`claude`) and keeps two-way Telegram communication attached to one active Claude session through the DD collector runtime. It is the Claude Code counterpart of the `telegram-codex` skill: the same collector-owned polling, pairing security, live tmux session sharing, and media handling, retargeted to the `claude` binary.

It drives the Claude Code CLI with the standard headless contract: managed Telegram replies run `claude -p "<prompt>" --resume <session-id> --output-format stream-json --verbose --dangerously-skip-permissions`, live TUI sharing matches `claude --resume <session-id>` processes, the shared transcript is the Claude Code JSONL at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, and `dashboard telegram-claude.start --version` proxies the real `claude --version` output.

It now also ships a Docker noVNC E2E lab so you can boot a full headed desktop
for Telegram Web, Claude, and later Playwright-driven automation without
installing Chrome or Claude manually on the host that is doing the proof.

## What It Solves

Most Telegram bot experiments stop at one-off scripts. They do not stay aligned with:

- Claude startup
- Dashboard runtime management
- repeatable PM/test/release gates
- session-specific conversation state

`telegram-claude` solves that by making Dashboard own the Telegram polling lifecycle.

## Current Runtime Model

After:

```bash
dashboard skills install telegram-claude
```

the managed startup chain is:

- `claude`
- `~/.developer-dashboard/cli/claude`
- `telegram-claude/cli/start`

When `dashboard telegram-claude.start` runs with `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CLAUDE_ENABLE_AUTOSTART=1`, it:

1. preserves the saved-session resume logic from the workspace session key and `~/.developer-dashboard/config/claude.json`
2. derives one workspace session id for Telegram collector ownership from the active shell path and ignores leaked ambient session ids from other workspaces
3. ensures there is exactly one collector named `telegram-claude-<session-id>` in `~/.developer-dashboard/config/config.json`
4. removes duplicate collector entries for that session if they exist and also removes stale same-workspace `telegram-claude-*` collectors that still point at the wrong session id
5. writes the active Claude reply target into `~/.telegram-claude/<session-id>/claude.session`
6. preserves or creates the pairing-security runtime for that session under `~/.telegram-claude/<session-id>/pairing.json`
7. restarts the DD collector with:
   - `cwd` fixed to the workspace where `dashboard telegram-claude.start` was run
   - `command` fixed to `dashboard telegram-claude.check-message <session-id>`
   - `interval` fixed to `5`
   - `rotation.lines` fixed to `100`
   - `mode` fixed to `singleton`
8. recycles any already-running `check-message <session-id>` worker for that session so the new managed behavior replaces stale long-lived code immediately
9. prunes stale orphaned duplicate `claude --resume <session-id>` processes for the mapped reply session before polling starts, so long-lived sessions do not keep leaking old live-session workers on the same tty
10. launches the real Claude binary with `--dangerously-skip-permissions`

During a managed Telegram reply, `telegram-claude` now also hydrates the reply prompt from recent persisted rows in that same saved Claude session transcript and then journals the inbound Telegram turn plus the outbound reply back into the transcript. That keeps later Telegram follow-up work and later resumed TUI history attached to one shared persisted Claude session instead of leaving Telegram as an isolated side channel.

If the mapped Claude session is already open inside a tmux-backed TUI and the live `claude --resume <session-id>` process can be matched back to a tmux pane, the worker now injects the Telegram request into that same live pane instead of immediately falling back to detached `claude -p --resume <session-id>`. In that live mode, the Telegram request becomes a real new TUI turn, the TUI commentary and final answer stream back to Telegram from the same transcript, and later TUI-originated turns can be mirrored back to the paired Telegram chat. Live-pane discovery now prefers the freshest tmux-backed `claude --resume <session-id>` process instead of the first stale match, and the tmux injector now submits the pasted turn with the Claude composer keystroke instead of leaving it stranded in the prompt. If the injected turn still never shows up in the transcript the worker fails fast and falls back to detached resume with an audit record instead of leaving Telegram stuck on `Claude verbose` plus `Resuming active Claude session`. TUI-originated mirrored turns now also keep Telegram `typing...` active until the final outbound Telegram reply send completes, even when that final assistant turn arrives in a later collector transcript poll, and the collector services the shared transcript before each Telegram poll so outbound TUI mirroring is not blocked behind a failing `getUpdates` call. The newest runtime hardening also keeps Telegram polling in a single-owner model: one live `check-message` worker owns `getUpdates` for the whole `~/.telegram-claude` runtime root, while other session workers keep servicing only outbound TUI transcript mirroring. When a session is paired or restarted, the same Telegram chat is cleared from older session runtimes so one chat does not keep multiple live collectors fighting over the same bot token.

`dashboard telegram-claude.start --version` is a pure metadata query that proxies the real `claude --version` output DD expects. DD can probe it safely without creating or restarting collectors.
Successful managed startup now hands off with `exec`, so the wrapper process does not stay resident as an extra long-lived `cli/start` parent after Claude takes over. The managed start path also prepends `--dangerously-skip-permissions` before it launches the real Claude process so direct Telegram-owned startup stays non-interactive on the same machine assumptions as managed resumed reply subprocesses. Ambient workspace `OLLAMA_MODEL` is no longer treated as an automatic provider override for Telegram-managed startup. If Telegram-owned startup really needs the Ollama model via `--model`, set `TELEGRAM_CLAUDE_OLLAMA_MODEL` explicitly.
On Windows, the generated `claude.cmd` wrapper now hands off into the managed
Perl launcher, and that launcher calls the skill-owned `cli/start` entrypoint
directly instead of going back through the currently broken DD dotted-command
helper path on `windev`. The June 5, 2026 Windows proof still needed a
PATH-visible `make.cmd` shim in `~/perl5/bin`, because current DD skill
installation invokes `make` before entering the skill and did not honor the
skill-local `make.cmd` from that installer path.
If you need runtime diagnostics for a broken managed reply, run:

```bash
dashboard telegram-claude.start --audit
```

That enables a per-session audit trail under `~/.telegram-claude/<session-id>/` without changing the collector contract.
It now also replaces any stale already-running worker for that same session, so the audit-enabled code path actually takes effect immediately instead of waiting for an old long-lived loop to die on its own.

The collector-owned polling loop is now the always-on path. The old standalone listener command is no longer the primary runtime model.
When `claude.session` exists for that collector session, `dashboard telegram-claude.check-message <session-id>` automatically routes replies back through that saved Claude session.
If `claude.session` is missing, the managed reply path falls back to the same saved-session mapping in `~/.developer-dashboard/config/claude.json` that `telegram-claude.start` uses.
Before the polling loop settles in, the worker prunes stale orphaned duplicate `claude --resume <session-id>` processes that are older than the freshest live tmux-backed owner on the same tty. That keeps long-running Telegram-managed sessions from accumulating unnecessary resident Claude processes and cuts the avoidable memory footprint of those workspaces.

## What The Skill Supports

Inbound Telegram update metadata:

- text
- photos
- videos
- audio
- voice
- documents and other files

Outbound Telegram actions:

- text replies
- local photo sends
- local audio sends
- local document sends

Telegram-native slash commands:

- `/help`
- `/status`

Attachment handling:

- metadata is available directly in updates and collector processing
- managed `dashboard telegram-claude.check-message <session-id>` now downloads inbound supported media into the session runtime before Claude replies
- downloaded Telegram photos and image documents are attached to resumed Claude replies by local path in the reply prompt so Claude opens them with its Read tool
- the Claude prompt still receives `*_local_path=` lines for downloaded files, but non-image media remains a local-path input for tool-based inspection rather than a direct binary model attachment
- direct `dashboard telegram-claude.download <FILE_ID>` and managed inbound-media downloads now use Telegram Bot API `getFile` query-string parameters correctly, so real photo and file downloads work in live runs

## Getting Started

Use this order instead of guessing which command to run first.

1. Change into the project you want Telegram to drive.

```bash
cd ~/projects/my-project
```

2. Register the workspace with Dashboard. This seeds the workspace shell, but `telegram-claude.start add` ultimately keys the saved Claude mapping to the active workspace path instead of trusting leaked ticket refs from some other shell.

```bash
dashboard workspace my-project
```

3. Save the Telegram bot token into the project-local `.env`.

```bash
printf 'TELEGRAM_BOT_TOKEN=123456:telegram-bot-token\n' >> .env
```

4. Make sure `.env` is ignored before you keep working.

```bash
printf '.env\n' >> .gitignore
```

5. Install or refresh the local Claude Telegram bridge.

```bash
dashboard telegram-claude.install 123456:telegram-bot-token
```

6. Start Claude normally inside that project.

```bash
claude
```

7. In Claude, send a small message such as `hi`, then run `/status` and note the active Claude session id.

8. Exit Claude, but stay in the same `dashboard workspace` shell.

9. Bind this workspace to that saved Claude session id from the same workspace shell.

```bash
dashboard telegram-claude.start add <claude-session-id>
```

10. Start or resume the managed Claude + Telegram bridge from that same workspace shell.

```bash
dashboard telegram-claude.start
```

11. If you want the runtime audit trail too, use:

```bash
dashboard telegram-claude.start --audit
```

After that, Telegram can drive the paired Claude session through the collector-owned bridge.

## Docker noVNC E2E Lab

Use the governed lab when you want a disposable desktop for Telegram Web login,
Claude, and later browser automation:

```bash
dashboard telegram-claude.e2e start
```

That lab:

- starts from `developer-dashboard:latest`
- runs as uid `1000` instead of `root`
- mounts the host `~/.claude` into the container user home so Claude auth is reused
- mounts a persistent Chrome profile directory under `~/.developer-dashboard/state/telegram-claude/e2e/chrome-profile`
- opens Telegram Web in official Google Chrome
- opens Claude in a visible terminal window
- exposes noVNC on `http://127.0.0.1:25900/vnc.html?autoconnect=1&resize=scale`
- exposes the Chrome DevTools port on `http://127.0.0.1:29222`

First-run Telegram login is still a real headed-browser step. Log in once in
the Chrome window through noVNC. After that, the mounted Chrome profile keeps
that Telegram Web session across `dashboard telegram-claude.e2e stop` /
`start` rebuilds instead of dropping back to the login screen every time.
The visible Claude xterm in that desktop now launches the bundled native Claude
binary directly instead of the npm-managed global wrapper, so the non-root lab
no longer opens on an `npm install -g @anthropic-ai/claude-code` permission failure.
The governed June 3, 2026 E2E proof also verified both message directions on
that live desktop: Telegram -> Claude -> Telegram and Claude -> Telegram from
the visible `telegram-claude` TUI window.

Check status:

```bash
dashboard telegram-claude.e2e status
```

Stop the lab:

```bash
dashboard telegram-claude.e2e stop
```

Stop the managed collector and recycle the same-session listener worker for the current workspace:

```bash
dashboard telegram-claude.stop
```

## Direct Command Reference

Use these when you already know the workflow above and need a specific helper.

```bash
dashboard telegram-claude.get-me
dashboard telegram-claude.updates
dashboard telegram-claude.check-message <session-id>
dashboard telegram-claude.download <FILE_ID>
dashboard telegram-claude.reply <CHAT_ID> 'Hello from Claude'
dashboard telegram-claude.pair <HEX_CODE>
dashboard telegram-claude.pair --clear-unknown-devices
dashboard telegram-claude.send-photo <CHAT_ID> ~/Pictures/demo.png
dashboard telegram-claude.send-audio <CHAT_ID> ~/Music/reply.mp3
dashboard telegram-claude.send-document <CHAT_ID> ~/Downloads/report.pdf
dashboard telegram-claude.auto-reply-start
```

## Collector Contract

The collector record created or healed by `dashboard telegram-claude.start` looks like this:

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

`dashboard telegram-claude.check-message <session-id>` is a long-running polling loop. Dashboard attempts to schedule it every five seconds, but singleton mode plus the same-session process lock prevents overlap while the existing loop is still alive. Per-session workspace state stays under `~/.telegram-claude/<session-id>/...`. One live worker owns Telegram `getUpdates` for that bot token's shared poll root and writes the shared poll state under `~/.telegram-claude/.shared/<sha1(bot-token)>/listener.offset` plus `~/.telegram-claude/.shared/<sha1(bot-token)>/listener.inbox.jsonl`. Other live session workers for the same bot skip Telegram polling and keep servicing only outbound TUI transcript mirroring. When `~/.telegram-claude/<session-id>/claude.session` exists, the worker resumes that Claude session to generate the Telegram reply text. If the shared `listener.offset` is missing or stale but the shared `listener.inbox.jsonl` proves a newer next offset, the worker rewrites `listener.offset` to that recovered value before polling so restart state stays truthful. Upgrades are automatic: the first `pair` or `check-message` run migrates the temporary token-scoped runtime layout, preserves flat per-session files, and scrubs any token root that only contains copied legacy flat shared poll files.
While Claude is processing a managed reply, the worker keeps Telegram `typing...` status active through both reply generation and the final outbound Telegram send so the indicator does not disappear before the reply arrives.
Instead of the old placeholder progress heartbeat, the worker now streams real step-by-step Claude verbose events from `claude -p --resume <session-id> --output-format stream-json --verbose` into one Telegram trace message that updates in place and stays visible in chat.
Managed Claude-session replies now open that verbose trace by default, including short conversational follow-up messages, and still emit an immediate kickoff line before richer Claude JSON events arrive.
When the mapped session is already live in a tmux-backed Claude TUI, the worker prefers the freshest matching live pane and transcript tailing before it falls back to detached resume. If the live pane never records the injected Telegram turn, the worker fails fast, audits the fallback reason, and retries through detached resume instead of waiting out the full live timeout.
If a Telegram verbose progress update fails mid-run, the worker now records that as a non-fatal progress error and still attempts final delivery. If the resumed Claude subprocess exits early or returns an empty reply, the worker now preserves exit status and stderr-tail detail for diagnosis instead of collapsing to a generic failure.
Before any managed Claude-session reply is allowed, the session now enforces a pairing gate. The first unpaired Telegram message receives one local pairing command reply in the form `d2 telegram-claude.pair <hexcode>`. If the same unpaired user keeps sending messages before that local pair command is run, the worker ignores them. Once the local pair command succeeds, only that paired chat can drive the session; other chats are ignored. If you missed the original challenge and need the current workspace to issue a fresh one again, run `dashboard telegram-claude.pair --clear-unknown-devices`. That clears only the current workspace session pairing state and records a shared claim in the current bot token's runtime root so the next unpaired Telegram message is routed back to that workspace even if another workspace for the same bot currently owns the live shared `getUpdates` worker. The session audit now records explicit pairing decisions such as `pairing.challenge.sent`, `pairing.ignored`, and `pairing.allowed` before managed Claude reply work starts.
For paired chats, supported Telegram slash commands are handled directly by `telegram-claude` before the managed Claude prompt path. Today that direct Telegram command surface is `/help` and `/status`. Surrounding whitespace or newline noise is stripped before command parsing so a padded Telegram `/status` or `/help` message still stays on the direct slash-command path instead of falling through into Claude prompt handling. Unsupported Telegram slash commands are rejected explicitly instead of being forwarded into Claude as ordinary prompt text. When the paired Claude session is already open in a tmux-backed TUI, Telegram `/status` now returns the real rendered Claude status panel from that live pane. If that pane is already showing the status panel, the visible live panel is reused immediately; otherwise `telegram-claude` injects the real Claude `/status` slash command into that pane and captures the rendered panel. If there is no live tmux-backed pane for that session, `telegram-claude` replies explicitly that real Claude `/status` is unavailable instead of returning a synthetic local summary.
The unpaired trigger message itself now stops at that pairing gate. It does not resume Claude, does not inject into a live tmux-backed Claude TUI pane, and does not append into the shared Claude session transcript.
For inbound non-text updates, the worker downloads supported attachments into `~/.telegram-claude/<session-id>/downloads/` before asking Claude to reply. Downloaded Telegram photos and image documents are referenced by local path in the reply prompt so Claude opens them with its Read tool. Other downloaded media still flows by local path for tool-based inspection. Claude can send a non-text reply back by returning directive lines:

```text
telegram_attachment_type=photo|audio|document
telegram_attachment_path=/absolute/local/path
telegram_attachment_caption=optional caption
```

Stop it with the workspace-local helper:

```bash
dashboard telegram-claude.stop
```

## Session State

The skill keeps per-session Telegram state under:

- `~/.telegram-claude/listener.offset`
- `~/.telegram-claude/listener.inbox.jsonl`
- `~/.telegram-claude/<session-id>/claude.session`
- `~/.telegram-claude/<session-id>/pairing.json`
- `~/.telegram-claude/<session-id>/downloads/`
- `~/.telegram-claude/<session-id>/audit.enabled`
- `~/.telegram-claude/<session-id>/audit.jsonl`
- `~/.telegram-claude/<session-id>/transcript.cursor`

`claude.session` stores the actual Claude session that Telegram replies should resume. That target may be different from the collector session name when the workspace session key maps to a saved Claude session.
The matching `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` transcript for that target session is now reused as shared persisted history for managed Telegram replies and receives readable Telegram user and assistant journal rows after each managed exchange.
`pairing.json` stores the paired Telegram chat id or the pending one-time local pairing challenge for that session. If a newer session claims the same chat, the older runtime is unpaired automatically.
`listener.offset` is the shared runtime-root Telegram poll cursor and is healed from the shared `listener.inbox.jsonl` immediately when inbox-ledger recovery proves a newer next offset.
`downloads/` stores inbound media that the managed collector downloaded for Claude inspection before reply generation.
`audit.enabled` opts the collector-owned worker into runtime audit capture.
`audit.jsonl` stores per-event diagnostic rows such as received updates, streamed progress events, progress callback failures, reply delivery failures, and final managed Claude reply exit details.

## Important Rules

- Do not claim binary media content was read unless the file was downloaded first.
- Do not claim outbound video send support; text, photo, audio, and document sending are implemented.
- Do not claim any media bytes were attached directly to the model; downloaded Telegram photos and image documents are referenced by local path in the reply prompt so the resumed Claude session opens them with its Read tool. Other media is referenced by local path for tool-based inspection only.
- Do expect the managed Telegram path to leave a readable verbose progress trace in chat instead of deleting a generic heartbeat message.
- Do expect managed Telegram sessions to stay locked until a local `dashboard telegram-claude.pair <hexcode>` command pairs one Telegram chat to that session.
- Do use `dashboard telegram-claude.start` for the real always-on path.
- Do treat `dashboard telegram-claude.check-message <session-id>` as a managed collector loop, not as a short one-off polling command.
- Do expect managed Telegram task replies to answer directly without boilerplate prefaces and to do the real in-session work before replying instead of sending a promise such as `will be done`.
- Do expect repeated nested `claude` calls inside one managed process tree to skip collector restarts because startup now carries a reentry guard.
