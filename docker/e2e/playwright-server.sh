#!/usr/bin/env bash
set -euo pipefail

export HOME="${TELEGRAM_CLAUDE_E2E_RUNTIME_HOME:-/home/dashboard}"
export NODE_PATH="${NODE_PATH:-/usr/local/lib/node_modules}"

runtime_root="${TELEGRAM_CLAUDE_E2E_RUNTIME_ROOT:-/tmp/telegram-claude-e2e}"
playwright_port="${TELEGRAM_CLAUDE_E2E_CHROME_INTERNAL_PORT:-9222}"
playwright_ws_path="${TELEGRAM_CLAUDE_E2E_PLAYWRIGHT_WS_PATH:-/playwright}"
playwright_log="${runtime_root}/playwright-server.log"

mkdir -p "${runtime_root}"

cat >"${runtime_root}/launch-playwright-server.js" <<EOF
const { chromium } = require("playwright-core");

(async () => {
  const server = await chromium.launchServer({
    executablePath: "/usr/bin/google-chrome",
    headless: true,
    host: "0.0.0.0",
    port: ${playwright_port},
    wsPath: "${playwright_ws_path}",
    chromiumSandbox: true,
    args: [
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-dev-shm-usage"
    ]
  });
  console.log(server.wsEndpoint());
})();
EOF

exec node "${runtime_root}/launch-playwright-server.js" >"${playwright_log}" 2>&1
