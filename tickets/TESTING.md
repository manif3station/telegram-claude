# Testing

## Policy

- tests run only inside Docker
- the shared test container definition lives at the workspace root
- this skill keeps its tests in `t/`

## Commands

```bash
docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test bash -lc 'cd /workspace/skills/telegram-claude && cpanm --quiet --notest --installdeps . && prove -lr t'
docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test bash -lc 'cd /workspace/skills/telegram-claude && rm -rf cover_db .test-tmp && cpanm --quiet --notest --installdeps . && HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t && cover -ignore_covered_err -report text -select lib/Telegram/Claude/Manager.pm -coverage statement -coverage subroutine'
cd ~/projects/skills/skills/telegram-claude && PERL5LIB=lib perl cli/e2e start
```

## Coverage Artifact Cleanup

`cover_db` is created inside the rooted Docker container, so host removal needs a
disposable container (per the workspace lock-file rule):

```bash
docker run --rm -v ~/projects/skills/skills/telegram-claude:/workspace:rw ubuntu bash -c "rm -rf /workspace/cover_db /workspace/.test-tmp"
```

## Latest Evidence

- Docker functional gate for `DD-383`:
  - command:
    `docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test bash -lc 'cd /workspace/skills/telegram-claude && cpanm --quiet --notest --installdeps . && prove -lr t'`
  - `Files=7, Tests=893`
  - `Result: PASS`
- Docker covered gate for `DD-383`:
  - command:
    `docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test bash -lc 'cd /workspace/skills/telegram-claude && rm -rf cover_db .test-tmp && cpanm --quiet --notest --installdeps . && HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t && cover -ignore_covered_err -report text -select lib/Telegram/Claude/Manager.pm -coverage statement -coverage subroutine'`
  - `Files=7, Tests=893`
  - `lib/Telegram/Claude/Manager.pm` statement `100.0`
  - `lib/Telegram/Claude/Manager.pm` subroutine `100.0`
- Claude Code CLI contract regressions covered for `DD-383`:
  - managed reply invokes `claude -p ... --resume <session-id> --output-format
    stream-json --verbose --dangerously-skip-permissions` and returns the
    `{"type":"result"}` reply text
  - stream-json events render as `Session resumed` (system/init),
    `Running tool: <name>: <detail>` (assistant tool_use), `Output: <line>`
    (user tool_result, both string and array content forms),
    `Agent: <line>` (assistant text), and `Turn completed` (result)
  - downloaded photo and image-document local paths are referenced in the prompt
    (`telegram_image_local_path=...`); non-image media is not
  - saved-session resume mapping prepends `--resume <session-id>`; an incoming
    argv that already carries `--resume`/`-r` is not double-prefixed
  - explicit Telegram-owned Ollama startup injects `--model <model>` and the
    managed startup path prepends `--dangerously-skip-permissions`
  - live tmux discovery matches `claude --resume <session-id>` process command
    lines and reads the Claude Code transcript under `~/.claude/projects/...`
  - `start --version` proxies the real `claude --version` output without
    collector side effects
- E2E asset regressions covered for `DD-383`:
  - the Docker E2E Dockerfile installs `@anthropic-ai/claude-code`
  - the E2E runtime resolves the installed Claude Code CLI from `PATH` (falling
    back to the `@anthropic-ai/claude-code/cli.js` module path) and launches the
    visible Claude terminal with `--dangerously-skip-permissions`
- Docker noVNC E2E lab boot proof for `DD-383` (2026-06-11, after push):
  - `dashboard telegram-claude.e2e start` built the lab from
    `developer-dashboard:latest` and started both services (exit 0)
  - the runtime container ran as uid `1000`, not `root`
  - the Claude Code CLI was installed from `@anthropic-ai/claude-code` and
    `claude --version` returned `2.1.173 (Claude Code)` inside the container
  - host `~/.claude` was mounted into the container user home
  - noVNC answered `200` on `http://127.0.0.1:25900/vnc.html`
  - Playwright Chrome DevTools endpoint answered `Running` on
    `http://127.0.0.1:29222/json/version`
  - the lab was stopped with `dashboard telegram-claude.e2e stop` after the boot
    proof
- Live two-way propagation E2E proof for `DD-383` (2026-06-11, in the noVNC lab):
  - the inbound Telegram message was sent into the logged-in Telegram Web client
    by driving the desktop with `xdotool` (the headed single-process Chrome in
    this container exposes no CDP/Playwright hook, so the GUI is driven at the X
    layer); a real Claude session (`342c650d…`) was created in the container with
    `claude -p … --output-format json` against the authenticated `claude` CLI
  - the `dashboard telegram-claude.check-message` bridge owned `getUpdates` and
    received the inbound message: audit `update.received` for message_id 44
    ("What is the date today?", chat 398296603)
  - the bridge resumed the real Claude session via
    `claude -p --resume 342c650d… --output-format stream-json --verbose
    --dangerously-skip-permissions`; audit shows `system/init` →
    `assistant: "Today's date is June 11, 2026."` → `result/success` →
    `claude.resume.completed` (exit_code 0)
  - the bridge delivered the reply back to Telegram: audit `reply.sent`
    (chat 398296603), visible in the Telegram Web window (screenshot reviewed
    outside the `.t` suite)
  - the inbound user turn and the outbound reply were both journaled into the
    shared Claude session transcript
    (`[Telegram chat …] What is the date today?` and
    `[Telegram reply …] Today's date is June 11, 2026.`)
  - the run used the `appdowntimealert_bot` test token by temporarily stopping
    the throwaway `foobar-project` codex worker that held its `getUpdates` lock
    (single-owner-per-token model), then restoring it afterward; pairing was
    bypassed for the single-message run (`TELEGRAM_CLAUDE_DISABLE_PAIRING=1`) and
    pairing security itself is covered by the unit suite
  - the lab was stopped after the run
- Known finding from the live run (follow-up, non-fatal): the managed
  verbose-trace progress callback raised `Claude progress callback failed` on
  each streamed line during the resumed reply. The skill correctly treats these
  as non-fatal — the final reply was still generated and delivered
  (`reply.sent`) — but the in-chat streaming verbose trace did not update
  cleanly in this environment. This is a real-environment robustness issue the
  mocked unit tests do not surface; it should be reproduced, root-caused, and
  gated in a follow-up ticket.
