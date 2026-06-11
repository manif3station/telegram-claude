# Usage

## Install The Skill

```bash
dashboard skills install telegram-claude
```

Current Windows note:

- the installed launcher chain is now `claude` -> `~/.developer-dashboard/cli/claude` -> `telegram-claude/cli/start`
- `telegram-claude` no longer requires a pre-resolved real `claude` path just to finish auto-setup
- current DD Windows skill installation still calls `make` before it enters the skill, so a PATH-visible `make` or `make.cmd` is still required on `windev` until DD core changes that behavior

## Docker noVNC E2E Lab

Bring up the headed Telegram and Claude desktop with:

```bash
dashboard telegram-claude.e2e start
```

The lab exposes:

- noVNC: `http://127.0.0.1:25900/vnc.html?autoconnect=1&resize=scale`
- Chrome DevTools for Playwright attach: `http://127.0.0.1:29222`

The container runs as uid `1000` and mounts the host `~/.claude` into the
container user home so Claude auth is already available there. It also mounts a
persistent Chrome profile directory at
`~/.developer-dashboard/state/telegram-claude/e2e/chrome-profile`.

Use the first run to complete real Telegram Web login in the headed Chrome
window. After that, `dashboard telegram-claude.e2e stop` and
`dashboard telegram-claude.e2e start` reuse the same mounted Chrome profile, so
the lab keeps the Telegram login instead of forcing a fresh sign-in on every
rebuild.
The visible Claude xterm now launches the bundled native Claude binary directly,
so the non-root desktop no longer falls into the npm global-wrapper self-update
permission failure that used to block interactive E2E work.
The governed desktop proof for this lab covered both Telegram -> Claude ->
Telegram and Claude -> Telegram from the visible `telegram-claude` xterm.

Check or stop it with:

```bash
dashboard telegram-claude.e2e status
dashboard telegram-claude.e2e stop
```

## Recommended Workflow

Use this path when you want Telegram to drive a real project session instead of starting from raw helper commands.

1. Change into the project you want Telegram to control.

```bash
cd ~/projects/my-project
```

2. Open the Dashboard workspace. This seeds the shell for the project, but `telegram-claude.start add` keys the saved Claude session mapping to the active workspace path instead of trusting leaked ticket refs from some other shell.

```bash
dashboard workspace my-project
```

3. Save the bot token into the project-local `.env`.

```bash
printf 'TELEGRAM_BOT_TOKEN=123456:telegram-bot-token\n' >> .env
```

4. Ignore `.env` before you keep working.

```bash
printf '.env\n' >> .gitignore
```

5. Install or refresh the local Claude Telegram plugin bridge.

```bash
dashboard telegram-claude.install 123456:telegram-bot-token
```

6. Start Claude in that same workspace shell.

```bash
claude
```

7. Send a small prompt such as `hi`, then run `/status` and note the active Claude session id.

8. Exit Claude, but stay in the same `dashboard workspace` shell.

9. Save the Claude session mapping for this workspace.

```bash
dashboard telegram-claude.start add <claude-session-id>
```

10. Start or resume the managed Telegram bridge.

```bash
dashboard telegram-claude.start
```

11. If you want the per-session audit trail too, use:

```bash
dashboard telegram-claude.start --audit
```

## Install The Local Claude Telegram Plugin

```bash
dashboard telegram-claude.install 123456:telegram-bot-token
```

That command writes the local Claude plugin, the stdio MCP config, the plugin-local `.env`, and the marketplace entry used by Claude.

## Start The Managed Telegram Runtime

Use:

```bash
dashboard telegram-claude.start
```

or launch Claude normally through the managed wrapper:

```bash
claude
```

With `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CLAUDE_ENABLE_AUTOSTART=1`, `telegram-claude.start` now does this:

1. loads the saved Claude-session mapping from `~/.developer-dashboard/config/claude.json` when the current workspace session key points to one
2. derives a stable Telegram collector session id from the active shell path and ignores leaked ambient session ids from other workspaces
3. ensures there is exactly one `telegram-claude-<session-id>` collector in `~/.developer-dashboard/config/config.json`
4. removes duplicates for that same collector name and heals stale same-workspace `telegram-claude-*` entries that still point at the wrong session id
5. writes the active Claude resume target to `~/.telegram-claude/<session-id>/claude.session`
6. preserves or creates pairing-security runtime in `~/.telegram-claude/<session-id>/pairing.json`
7. runs:

```bash
dashboard restart collector telegram-claude-<session-id>
```

8. recycles any already-running `dashboard telegram-claude.check-message <session-id>` worker for that same session
9. prunes stale orphaned duplicate `claude --resume <session-id>` processes for the mapped reply session before polling begins
10. launches the real Claude binary with `--dangerously-skip-permissions`

`dashboard telegram-claude.start --version` is intentionally side-effect free and proxies the real `claude --version` output DD launcher checks expect, so DD command-family discovery can probe it without touching collectors.
On a real startup, the launcher now uses `exec` for real Claude handoff, so a successful run does not leave an extra resident `cli/start` wrapper process behind. The managed start path also prepends `--dangerously-skip-permissions` before that handoff so direct Telegram-owned startup stays non-interactive on the same machine assumptions as managed resumed reply subprocesses.
Ambient workspace `OLLAMA_MODEL` is ignored by Telegram-managed startup. If you intentionally want Telegram-managed startup to inject the Ollama model via `--model`, set `TELEGRAM_CLAUDE_OLLAMA_MODEL` explicitly.
If you need managed-reply runtime diagnostics, start with:

```bash
dashboard telegram-claude.start --audit
```

That enables per-session audit rows in `~/.telegram-claude/<session-id>/audit.jsonl`.
Because startup now recycles an already-running worker for that session before the collector restart, the audited code path takes effect immediately instead of leaving an old long-lived worker alive.

If `claude.session` is missing later, the managed reply path falls back to the same saved-session mapping in `~/.developer-dashboard/config/claude.json` instead of blindly using the collector session id.
When the saved Claude session exists, managed Telegram replies now also hydrate from recent persisted transcript rows for that same Claude session and then append readable Telegram user and assistant turns back into it. That keeps Telegram follow-up work and later resumed TUI history attached to one shared persisted Claude session.
If that mapped Claude session is already open in a tmux-backed TUI and the live `claude --resume <session-id>` process can be matched back to a tmux pane, the worker now injects the Telegram request into that same live pane. In that live mode, the open TUI sees the Telegram-originated turn directly, and the paired Telegram chat receives progress plus the final answer from the same live session transcript. Live-pane discovery now prefers the freshest tmux-backed `claude --resume <session-id>` process instead of the first stale match. If no matching tmux pane is found, or if the injected Telegram turn never appears in the live transcript, the runtime falls back to a detached `claude -p --resume <session-id>` reply and records the reason in the session audit. The latest live-sync hardening also keeps Telegram polling in a single-owner model. One live `check-message` worker owns `getUpdates` for the whole `~/.telegram-claude` runtime root, while non-owner session workers keep servicing only outbound TUI transcript mirroring. Pairing or restarting one session also clears the same Telegram chat from older session runtimes so one chat has one active session owner.

## Collector-Owned Polling Loop

The collector command is:

```bash
dashboard telegram-claude.check-message <session-id>
```

This is a long-running polling loop, not a short one-shot helper.

The collector definition installed or healed by `telegram-claude.start` is:

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

Dashboard may try to schedule it every five seconds, but singleton mode plus the same-session process lock prevents a second `check-message <session-id>` copy from starting while the existing loop is still running. Per-session workspace state stays under `~/.telegram-claude/<session-id>/...`. One live worker owns Telegram `getUpdates` for that bot token's shared poll root and persists that shared poll state in `~/.telegram-claude/.shared/<sha1(bot-token)>/listener.offset` plus `~/.telegram-claude/.shared/<sha1(bot-token)>/listener.inbox.jsonl`. Other live session workers for the same bot skip Telegram polling and keep servicing only outbound TUI transcript mirroring. If `~/.telegram-claude/<session-id>/claude.session` exists, the worker automatically resumes that Claude session to generate the Telegram reply. If that file is missing, the worker falls back to the saved-session mapping in `~/.developer-dashboard/config/claude.json`. If the shared `listener.inbox.jsonl` proves a newer next offset than the shared `listener.offset`, the worker rewrites `listener.offset` before polling so restart state and replay diagnostics stay aligned. Before normal polling continues, the worker prunes stale orphaned duplicate `claude --resume <session-id>` processes that are older than the freshest live tmux-backed owner on the same tty. While that managed reply is being processed, the worker keeps Telegram `typing...` status active until the final outbound Telegram send attempt completes. Instead of the old placeholder `Claude is still working on your request...` heartbeat, the worker now streams real `claude -p --resume <session-id> --output-format stream-json --verbose` step events into one Telegram trace message that updates in place and remains visible after delivery. Managed Claude-session replies now open that verbose trace by default, including short conversational follow-up messages, and still emit an immediate kickoff line before richer Claude JSON events arrive. When the mapped session is already live in a tmux-backed Claude TUI, the worker now prefers the freshest matching live pane and transcript tailing before it falls back to detached resume. If the live pane never records the injected Telegram turn, the worker fails fast, audits the reason, and retries through detached resume instead of leaving the chat stuck on the kickoff line. TUI-originated turns are also mirrored back into the paired Telegram chat from the same transcript stream, and those mirrored turns now keep Telegram `typing...` active until the final outbound Telegram reply send completes even when the final assistant turn lands in a later collector transcript poll. On upgrade, the first `pair` or `check-message` run migrates the temporary token-scoped runtime layout, preserves flat per-session files, and scrubs any token root that only contains copied legacy flat shared poll files automatically.
Before any managed Claude-session reply is allowed, the session pairing gate must be satisfied. The first unpaired Telegram message receives a single pairing reply in the form `d2 telegram-claude.pair <hexcode>`. If that user keeps sending messages before the local pair command is run, the worker ignores them. Once the local pair command succeeds, only that paired Telegram chat can drive the session. If that pairing reply was missed, `dashboard telegram-claude.pair --clear-unknown-devices` clears only the current workspace session pairing state and records a shared claim in the current bot token's runtime root so the next unpaired inbound Telegram message is routed back to that workspace even if some other workspace for the same bot currently owns the shared `getUpdates` loop. The per-session audit records explicit pairing decisions as `pairing.challenge.sent`, `pairing.ignored`, and `pairing.allowed` before managed Claude reply work starts.
That first unpaired trigger message now stops at the pairing boundary completely: it does not resume Claude, does not inject into a live tmux-backed Claude TUI pane, and does not append into the shared Claude session transcript.
For paired chats, supported Telegram slash commands are handled directly by `telegram-claude` before the managed Claude resume path. Today that direct Telegram slash-command surface is `/help` and `/status`. Surrounding whitespace or newline noise is stripped before command parsing so a padded Telegram `/status` or `/help` message still stays on the direct slash-command path instead of falling through into Claude prompt handling. Unsupported Telegram slash commands are rejected explicitly instead of being forwarded into Claude as ordinary prompt text. When the paired Claude session is already open inside a tmux-backed TUI, Telegram `/status` now captures the real rendered Claude status panel from that live pane. If the pane is already showing the status panel, `telegram-claude` reuses that visible live block immediately; otherwise it injects the real Claude `/status` slash command into that pane and captures the new render. If there is no live tmux-backed pane for that session, `telegram-claude` replies explicitly that real Claude `/status` is unavailable instead of inventing a detached local summary.
If a verbose progress edit fails, that failure is now treated as non-fatal and the worker still attempts final Telegram delivery. If the resumed Claude subprocess exits early or returns no final text, the worker now records exit code, signal, stderr tail, and streamed progress events in the audit file so the cut-off can be diagnosed.
Before that managed reply is generated, supported inbound Telegram media is downloaded into the session runtime. Downloaded Telegram photos and image documents are attached to resumed Claude replies by local path in the reply prompt so Claude opens them with its Read tool. Other downloaded media is still exposed through `*_local_path=` lines in the reply prompt for tool-based inspection.
Managed task replies also tell Claude to answer directly without boilerplate prefaces and to do the actual work before replying instead of returning promise-only placeholders such as `will be done`.
Nested managed `claude` invocations inside the same process tree inherit a startup reentry guard, so they do not keep re-running collector restart side effects.

Stop it with Dashboard:

```bash
dashboard telegram-claude.stop
```

That stops the managed collector for the current workspace session and recycles
the same-session long-running `dashboard telegram-claude.check-message
<session-id>` worker so stale prompt processing cannot continue after the stop.

## Pair A Session To The Pending Telegram Chat

When a session is unpaired, the first inbound Telegram message gets this reply:

```bash
d2 telegram-claude.pair <HEX_CODE>
```

Run that locally in the same workspace:

```bash
dashboard telegram-claude.pair <HEX_CODE>
```

That binds the pending Telegram chat to the current workspace session. After that, the paired chat works normally and other chats are ignored.

If you missed the Telegram pairing reply and want the current workspace
session to issue a new one on the next inbound message, clear only this
session's pairing state:

```bash
dashboard telegram-claude.pair --clear-unknown-devices
```

That reset is workspace-local. It does not clear or reassign any other
workspace session pairing, and it claims the next unpaired inbound Telegram
message for this workspace under the shared poll-owner model.

## Poll Updates Directly

```bash
dashboard telegram-claude.updates
```

That update payload can include metadata for:

- text
- photos
- video
- audio
- voice
- documents/files

## Download Inbound Media

```bash
dashboard telegram-claude.download <FILE_ID>
```

Use that for photos, videos, audio, voice, PDFs, and other Telegram-hosted files whenever the actual content must be inspected.

The managed `check-message` loop now performs that download step automatically for inbound supported media before Claude replies.
The direct `download` command and the managed collector-owned media path both use Telegram Bot API `getFile` query-string parameters correctly, so real inbound Telegram photo and file downloads work in live runs.

## Send Replies

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

Managed Claude replies can also send those files back automatically by returning:

```text
telegram_attachment_type=photo|audio|document
telegram_attachment_path=/absolute/local/path
telegram_attachment_caption=optional caption
```

## `/start` Acknowledgement Helper

```bash
dashboard telegram-claude.auto-reply-start
```

## Session Runtime Files

Per-session runtime state lives under:

- `~/.telegram-claude/listener.offset`
- `~/.telegram-claude/listener.inbox.jsonl`
- `~/.telegram-claude/<session-id>/claude.session`
- `~/.telegram-claude/<session-id>/pairing.json`
- `~/.telegram-claude/<session-id>/downloads/`
- `~/.telegram-claude/<session-id>/audit.enabled`
- `~/.telegram-claude/<session-id>/audit.jsonl`
- `~/.telegram-claude/<session-id>/transcript.cursor`

`listener.offset` keeps the shared runtime-root Telegram update offset and is healed immediately from the shared inbox ledger when inbox recovery proves a newer next offset.

`listener.inbox.jsonl` keeps the shared runtime-root inbound update ledger for the active Telegram poll owner.

`transcript.cursor` tracks how far the worker has already mirrored the shared Claude transcript back into Telegram for TUI-originated live turns.

`claude.session` keeps the real Claude session that the collector-owned `check-message <session-id>` worker resumes to generate Telegram replies.
The matching `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` transcript for that target session is now reused as the shared persisted history source for managed Telegram replies and receives readable Telegram user and assistant journal rows after each managed exchange.
`pairing.json` keeps the paired chat id or the pending pairing challenge for that session. When a newer session claims that same Telegram chat, the older session is unpaired automatically.
`downloads/` keeps inbound supported Telegram media that was downloaded for Claude before reply generation.
`audit.enabled` turns on runtime audit capture for that collector session.
`audit.jsonl` records received updates, progress-stream failures, managed Claude stream-json progress events, stderr-tail details, and final reply success or failure.

## Media Handling Rule

`telegram-claude` can receive and route metadata for text, images, video, audio, voice, PDFs, and other files.

Downloaded Telegram photos and image documents are the only inbound media currently referenced by local path in the reply prompt so the resumed Claude session opens them with its Read tool.
Downloaded audio, voice, video, PDFs, and other non-image files remain local-path inputs for tool-based inspection in the resumed Claude session.

It must not claim that a binary attachment was read just because the update metadata arrived. Download the file by `file_id` first when the content itself matters.
