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
- Remaining operator step: the live two-way propagation E2E (manual Telegram Web
  login in the headed Chrome window, pair a Claude session, then prove
  Telegram -> Claude -> Telegram and Claude -> Telegram with screenshot review)
  is performed by an operator per the standing runbook at
  `~/projects/skills/simulator/doc/telegram-claude/README.md`. It needs a
  Telegram bot token and the manual headed-browser login, so it is not run
  inside the automated `.t` suite.
