# Overview

`telegram-claude` packages a Telegram Bot API bridge as a governed DD skill. The skill owns two things:

1. a Perl command surface for install, poll, download, reply, and always-on listener flows
2. a generated local Claude plugin with a stdio MCP server

The current release also adds a third operator surface:

3. a skill-owned Docker noVNC E2E lab for Telegram Web, Claude, and Playwright attach

The skill is aimed at a personal local Claude runtime where plugin files live under `~/.claude/.tmp/plugins/` and, when present, a mirrored runtime under `~/_claude/michael/.tmp/plugins/`.

The E2E lab keeps that same local-auth assumption by mounting the host
`~/.claude` into a non-root uid `1000` container runtime, then opening Telegram
Web in official Google Chrome and Claude in a visible terminal on the same
desktop. The Chrome profile now lives in
`~/.developer-dashboard/state/telegram-claude/e2e/chrome-profile`, so one real
headed Telegram Web login can persist across lab rebuilds. The visible Claude
window launches the bundled native Claude binary directly, which keeps the
desktop operator-ready under the non-root runtime instead of dropping into the
npm global-wrapper self-update failure path.

For the managed startup path, `dashboard telegram-claude.start` now keeps collector ownership tied to the active shell path. It intentionally ignores leaked ambient workspace session ids plus ambient `OLLAMA_MODEL` so nested Claude chains or unrelated workspace provider env do not create the wrong collector session or recurse through a wrapped Ollama launch path.

For the listener path, the skill keeps runtime state under `~/.telegram-claude/<session-id>/` by default:

- `listener.offset`
- `listener.inbox.jsonl`

Session id resolution order is:

1. `TELEGRAM_CLAUDE_SESSION_ID`
2. `CLAUDE_SESSION_ID`
3. `default`

Inbound update support covers:

- text
- photos
- video
- audio
- voice
- documents and files

Outbound send support currently covers:

- text replies
- photos
- audio
- documents

Managed media understanding currently splits into two paths:

- downloaded Telegram photos and image documents are referenced by local path in the reply prompt so Claude opens them with its Read tool
- audio, voice, video, PDFs, and other non-image files are downloaded locally and exposed by path for tool-based inspection, not direct binary model attachment

Managed reply progress now uses a third path:

- Telegram sees a preserved in-chat verbose trace built from real `claude -p --resume <session-id> --output-format stream-json --verbose` agent and command events instead of a generic progress heartbeat
- live tmux-backed Telegram injection now uses the Claude composer submit keystroke, so pasted Telegram turns are committed into the TUI instead of being left in the prompt buffer
- shared-transcript mirroring is serviced before each Telegram poll cycle, so TUI-originated outbound mirroring is not blocked behind a transient `getUpdates` failure
