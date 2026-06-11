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
- Note: the standing Telegram simulator E2E run (live noVNC desktop,
  Telegram -> Claude -> Telegram and Claude -> Telegram) is performed after the
  skill repository is pushed, per the workspace simulator E2E rule.
