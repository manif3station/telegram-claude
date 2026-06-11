#!/usr/bin/env bash
set -euo pipefail

role="${TELEGRAM_CLAUDE_E2E_ROLE:-desktop}"
if [[ "${role}" == "playwright" ]]; then
  exec /usr/local/bin/telegram-claude-e2e-playwright
fi

exec /usr/local/bin/telegram-claude-e2e-runtime
