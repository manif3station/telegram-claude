#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:1
export HOME="${TELEGRAM_CLAUDE_E2E_RUNTIME_HOME:-/home/dashboard}"

workspace_dir="${TELEGRAM_CLAUDE_E2E_WORKSPACE_PATH:-/opt/telegram-claude}"
if [[ ! -d "${workspace_dir}" ]]; then
  workspace_dir="/opt/telegram-claude"
fi

runtime_root="${TELEGRAM_CLAUDE_E2E_RUNTIME_ROOT:-/tmp/telegram-claude-e2e}"
chrome_debug_port="${TELEGRAM_CLAUDE_E2E_CHROME_DEBUG_PORT:-29222}"
telegram_url="${TELEGRAM_CLAUDE_E2E_TELEGRAM_URL:-https://web.telegram.org/a/}"
telegram_profile_dir="${HOME}/.config/google-chrome-e2e"
runtime_profile_dir="${runtime_root}/chrome-runtime-profile"
profile_format_version="telegram-claude-e2e-profile-v2-single-process"
profile_version_file="${telegram_profile_dir}/.telegram-claude-profile-version"
playwright_ws_path="${TELEGRAM_CLAUDE_E2E_PLAYWRIGHT_WS_PATH:-/playwright}"
claude_native_bin="$(command -v claude || true)"
if [[ -z "${claude_native_bin}" ]]; then
  claude_native_bin="/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
fi

if [[ ! -x "${claude_native_bin}" ]]; then
  echo "Missing installed Claude Code CLI binary: ${claude_native_bin}" >&2
  exit 1
fi

mkdir -p "${runtime_root}" "${telegram_profile_dir}"
if [[ ! -f "${profile_version_file}" ]] || [[ "$(<"${profile_version_file}")" != "${profile_format_version}" ]]; then
  find "${telegram_profile_dir}" -mindepth 1 -maxdepth 1 ! -name '.telegram-claude-profile-version' -exec rm -rf {} +
  printf '%s\n' "${profile_format_version}" >"${profile_version_file}"
fi
rm -rf "${runtime_profile_dir}"
mkdir -p "${runtime_profile_dir}"
if [[ -d "${telegram_profile_dir}" ]]; then
  cp -a "${telegram_profile_dir}/." "${runtime_profile_dir}/" 2>/dev/null || true
fi
rm -f \
  "${runtime_profile_dir}/SingletonCookie" \
  "${runtime_profile_dir}/SingletonLock" \
  "${runtime_profile_dir}/SingletonSocket"
rm -f \
  "${runtime_profile_dir}/Default/Current Session" \
  "${runtime_profile_dir}/Default/Current Tabs" \
  "${runtime_profile_dir}/Default/Last Session" \
  "${runtime_profile_dir}/Default/Last Tabs"
rm -rf "${runtime_profile_dir}/Default/Sessions"

cleanup() {
  kill "${telegram_chrome_pid:-0}" "${claude_pid:-0}" "${novnc_pid:-0}" "${vnc_pid:-0}" "${openbox_pid:-0}" "${xvfb_pid:-0}" 2>/dev/null || true
  if [[ -d "${runtime_profile_dir}" ]]; then
    mkdir -p "${telegram_profile_dir}"
    shopt -s dotglob nullglob
    find "${telegram_profile_dir}" -mindepth 1 -maxdepth 1 ! -name '.telegram-claude-profile-version' -exec rm -rf {} +
    cp -a "${runtime_profile_dir}/." "${telegram_profile_dir}/" 2>/dev/null || true
    printf '%s\n' "${profile_format_version}" >"${profile_version_file}"
    shopt -u dotglob nullglob
  fi
}

trap cleanup EXIT TERM INT

Xvfb :1 -screen 0 1440x900x24 >"${runtime_root}/xvfb.log" 2>&1 &
xvfb_pid="$!"
sleep 1

openbox >"${runtime_root}/openbox.log" 2>&1 &
openbox_pid="$!"
sleep 1

pkill -f /usr/bin/google-chrome 2>/dev/null || true
sleep 1

google-chrome \
  --single-process \
  --test-type \
  --disable-gpu \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --disable-crash-reporter \
  --disable-crashpad-for-testing \
  --hide-crash-restore-bubble \
  --password-store=basic \
  --user-data-dir="${runtime_profile_dir}" \
  "${telegram_url}" >"${runtime_root}/telegram-chrome.log" 2>&1 &
telegram_chrome_pid="$!"

x11vnc -display :1 -forever -shared -rfbport 5900 -nopw >"${runtime_root}/x11vnc.log" 2>&1 &
vnc_pid="$!"

websockify --web=/usr/share/novnc/ 6080 localhost:5900 >"${runtime_root}/novnc.log" 2>&1 &
novnc_pid="$!"

xterm -geometry 90x42+24+24 -T "Claude" -e bash -lc 'cd "$1" && "$2" --dangerously-skip-permissions; exec bash' _ "${workspace_dir}" "${claude_native_bin}" >"${runtime_root}/claude-xterm.log" 2>&1 &
claude_pid="$!"

(
  for _ in 1 2 3 4 5; do
    sleep 1
    claude_window="$(DISPLAY=:1 xdotool search --name 'Claude' | head -n 1 || true)"
    if [[ -n "${claude_window}" ]]; then
      DISPLAY=:1 xdotool windowraise "${claude_window}" windowactivate --sync "${claude_window}" key --window "${claude_window}" Return || true
    fi
  done
) >/dev/null 2>&1 &

(
  for _ in $(seq 1 30); do
    sleep 1
    claude_window="$(DISPLAY=:1 xdotool search --name 'Claude' | head -n 1 || true)"
    chrome_window="$(DISPLAY=:1 xdotool search --onlyvisible --class google-chrome | head -n 1 || true)"
    if [[ -n "${claude_window}" && -n "${chrome_window}" ]]; then
      DISPLAY=:1 xdotool windowsize "${claude_window}" 620 820 windowmove "${claude_window}" 20 40 || true
      DISPLAY=:1 xdotool windowsize "${chrome_window}" 760 820 windowmove "${chrome_window}" 660 40 windowraise "${chrome_window}" windowactivate --sync "${chrome_window}" || true
      exit 0
    fi
  done
) >/dev/null 2>&1 &

python3 - <<'PY' "${runtime_root}" "${workspace_dir}" "${chrome_debug_port}" "${telegram_url}" "${playwright_ws_path}" "${claude_native_bin}"
import json, os, sys
runtime_root, workspace_dir, chrome_debug_port, telegram_url, playwright_ws_path, claude_native_bin = sys.argv[1:7]
payload = {
    "status": "running",
    "workspace_path": workspace_dir,
    "novnc_url": "http://127.0.0.1:25900/vnc.html?autoconnect=1&resize=scale",
    "chrome_debug_url": f"ws://127.0.0.1:{chrome_debug_port}{playwright_ws_path}",
    "chrome_bootstrap_url": telegram_url,
    "playwright_ws_endpoint": f"ws://127.0.0.1:{chrome_debug_port}{playwright_ws_path}",
    "telegram_url": telegram_url,
    "claude_command": f"{claude_native_bin} --dangerously-skip-permissions",
}
with open(os.path.join(runtime_root, "status.json"), "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
PY

while :; do
  sleep 3600
done
