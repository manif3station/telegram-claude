#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;

my $dockerfile = do {
    open my $fh, '<', 'docker/e2e/Dockerfile' or die $!;
    local $/;
    <$fh>;
};

like( $dockerfile, qr/^FROM developer-dashboard:latest$/m, 'E2E Dockerfile starts from developer-dashboard:latest' );
like( $dockerfile, qr/google-chrome-stable_current_amd64\.deb/, 'E2E Dockerfile installs the official Google Chrome deb package' );
like( $dockerfile, qr/npm install -g \@anthropic-ai\/claude-code/, 'E2E Dockerfile installs the Claude Code CLI' );
like( $dockerfile, qr/npm install -g playwright-core\@1\.59\.1/, 'E2E Dockerfile pins Playwright Core to the host-compatible version for remote attach' );
like( $dockerfile, qr/USER 1000:1000/, 'E2E Dockerfile runs the final desktop runtime as uid 1000' );

my $compose = do {
    open my $fh, '<', 'docker-compose.e2e.yml' or die $!;
    local $/;
    <$fh>;
};

like( $compose, qr/\$\{TELEGRAM_CLAUDE_E2E_NOVNC_PORT\}:6080/, 'E2E compose exposes the governed noVNC port mapping' );
like( $compose, qr/\$\{HOME\}\/\.claude:\/home\/dashboard\/\.claude/, 'E2E compose mounts the host ~/.claude into the container user home' );
like( $compose, qr/\$\{TELEGRAM_CLAUDE_E2E_CHROME_DEBUG_PORT\}:9222/, 'E2E compose exposes the host Playwright port to the container Chrome DevTools port' );
like( $compose, qr/\$\{TELEGRAM_CLAUDE_E2E_CHROME_PROFILE_DIR\}:\/home\/dashboard\/\.config\/google-chrome-e2e/, 'E2E compose mounts a persistent Chrome profile directory' );
like( $compose, qr/TELEGRAM_CLAUDE_E2E_ROLE:\s*desktop/s, 'E2E compose marks the noVNC desktop service as the desktop role' );
like( $compose, qr/TELEGRAM_CLAUDE_E2E_ROLE:\s*playwright/s, 'E2E compose adds a separate Playwright service role so browser attach stays isolated from the visible Telegram desktop' );
like( $compose, qr/cap_add:\s*\n\s*-\s*SYS_ADMIN/s, 'E2E compose grants the Chrome-friendly SYS_ADMIN capability' );
like( $compose, qr/security_opt:\s*\n\s*-\s*seccomp=unconfined/s, 'E2E compose relaxes seccomp so Chrome can use its supported sandbox path' );
like( $compose, qr/shm_size:\s*2gb/, 'E2E compose reserves a larger shared-memory segment for Chrome' );

my $runtime = do {
    open my $fh, '<', 'docker/e2e/runtime.sh' or die $!;
    local $/;
    <$fh>;
};

like( $runtime, qr/google-chrome/, 'E2E runtime launches Google Chrome' );
like( $runtime, qr/--single-process/, 'E2E runtime forces the visible Chrome onto the single-process path so headed navigation renders correctly in the noVNC container' );
like( $runtime, qr/--test-type/, 'E2E runtime uses Chrome test mode to suppress first-run blockers in the lab' );
like( $runtime, qr/--disable-gpu/, 'E2E runtime uses software rendering for stable noVNC page painting' );
like( $runtime, qr/pkill -f \/usr\/bin\/google-chrome/, 'E2E runtime clears stray Chrome processes before launching the governed visible browser' );
like( $runtime, qr/telegram_profile_dir=.*google-chrome-e2e/s, 'E2E runtime keeps the Telegram login browser on the persistent Chrome profile mount' );
like( $runtime, qr/runtime_profile_dir=.*chrome-runtime-profile/s, 'E2E runtime uses a runtime-local working copy of the Telegram profile so Chrome starts cleanly against the persistent mount' );
like( $runtime, qr/profile_format_version=.*single-process/s, 'E2E runtime versions the persisted Telegram profile so incompatible pre-fix lab state is reset automatically' );
like( $runtime, qr/\.telegram-claude-profile-version/, 'E2E runtime records a profile-version marker alongside the persisted Telegram browser profile' );
like( $runtime, qr/cp -a "\$\{telegram_profile_dir\}\/\." "\$\{runtime_profile_dir\}\/"/s, 'E2E runtime seeds the working browser profile from the persisted Telegram profile mount' );
like( $runtime, qr/SingletonLock/, 'E2E runtime clears stale Chrome singleton locks from the runtime browser profile before launch' );
like( $runtime, qr/Default\/Current Session/, 'E2E runtime clears Chrome session-restore files from the runtime browser profile before launch' );
like( $runtime, qr/cp -a "\$\{runtime_profile_dir\}\/\." "\$\{telegram_profile_dir\}\/"/s, 'E2E runtime syncs the working browser profile back onto the persisted Telegram profile mount during cleanup' );
like( $runtime, qr/--disable-crash-reporter/, 'E2E runtime disables Chrome crash reporting in the visible Telegram browser path' );
like( $runtime, qr/--disable-crashpad-for-testing/, 'E2E runtime disables Crashpad in the visible Telegram browser path so the mounted profile does not crash Chrome on startup' );
like( $runtime, qr/--hide-crash-restore-bubble/, 'E2E runtime suppresses the Chrome restore bubble in the visible Telegram browser path' );
unlike( $runtime, qr/--no-sandbox/, 'E2E runtime no longer forces Chrome into no-sandbox mode when the container grants a supported sandbox path' );
unlike( $runtime, qr/--disable-setuid-sandbox/, 'E2E runtime no longer disables the Chrome setuid sandbox path in the lab runtime' );
like( $runtime, qr/"\$\{telegram_url\}" >"\$\{runtime_root\}\/telegram-chrome\.log"/, 'E2E runtime launches the headed Chrome directly to Telegram Web' );
like( $runtime, qr/--user-data-dir="\$\{runtime_profile_dir\}"/, 'E2E runtime points the visible Telegram browser at the runtime-local working profile copy' );
like( $runtime, qr/playwright_ws_endpoint/s, 'E2E runtime records the externally reachable Playwright websocket endpoint in status.json' );
like( $runtime, qr/python3 - <<'PY'.*"\$\{claude_native_bin\}"/s, 'E2E runtime passes the native Claude binary path into the status writer block' );
like( $runtime, qr/xterm .*claude/s, 'E2E runtime opens Claude in a visible terminal window' );
like( $runtime, qr/claude_native_bin="\$\(command -v claude/s, 'E2E runtime resolves the installed Claude Code CLI binary from PATH' );
like( $runtime, qr/\@anthropic-ai\/claude-code\/cli\.js/s, 'E2E runtime falls back to the installed Claude Code CLI module path' );
like( $runtime, qr/\$2" --dangerously-skip-permissions/s, 'E2E runtime launches the visible Claude terminal with the non-interactive skip-permissions flag' );
unlike( $runtime, qr/--dangerously-bypass-approvals-and-sandbox/, 'E2E runtime no longer uses the Codex-style bypass flag' );
like( $runtime, qr/windowmove "\$\{claude_window\}" 20 40/s, 'E2E runtime places the Claude terminal into a fixed left-side slot so it does not cover the browser' );
like( $runtime, qr/windowmove "\$\{chrome_window\}" 660 40/s, 'E2E runtime places the Telegram browser into a visible right-side slot for immediate login access' );
like( $runtime, qr/websockify --web=\/usr\/share\/novnc\/ 6080 localhost:5900/, 'E2E runtime serves noVNC over websockify' );
like( $runtime, qr/telegram_chrome_pid=.*?x11vnc/s, 'E2E runtime starts the visible Chrome before the noVNC sidecars so Chrome does not inherit their long-lived sockets' );

my $playwright = do {
    open my $fh, '<', 'docker/e2e/playwright-server.sh' or die $!;
    local $/;
    <$fh>;
};

like( $playwright, qr/NODE_PATH=.*\/usr\/local\/lib\/node_modules/, 'E2E Playwright service exposes the global Node module path so the server script can load playwright-core' );
like( $playwright, qr/chromium\.launchServer/s, 'E2E Playwright service launches a dedicated Playwright browser server' );
like( $playwright, qr/wsPath:\s*"\$\{playwright_ws_path\}"/s, 'E2E Playwright service uses a deterministic websocket path for host-side attach' );
like( $playwright, qr/headless:\s*true/s, 'E2E Playwright service keeps the browser server headless so it does not interfere with the visible Telegram desktop' );
like( $playwright, qr/chromiumSandbox:\s*true/s, 'E2E Playwright service forces the browser server onto the supported Chrome sandbox path inside the container' );

done_testing;
