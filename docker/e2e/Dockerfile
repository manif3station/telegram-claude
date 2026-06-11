FROM developer-dashboard:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV HOME=/home/dashboard
ENV TELEGRAM_CLAUDE_E2E_RUNTIME_HOME=/home/dashboard
ENV TELEGRAM_CLAUDE_E2E_RUNTIME_ROOT=/tmp/telegram-claude-e2e
ENV PATH=/home/dashboard/.npm-global/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fonts-liberation \
    gnupg \
    novnc \
    openbox \
    python3 \
    python3-websockify \
    scrot \
    socat \
    sudo \
    websockify \
    wget \
    xdotool \
    x11vnc \
    xdg-utils \
    xterm \
    xvfb \
 && rm -rf /var/lib/apt/lists/*

RUN wget -O /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
 && apt-get update \
 && apt-get install -y /tmp/google-chrome-stable_current_amd64.deb \
 && rm -f /tmp/google-chrome-stable_current_amd64.deb \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code \
 && npm install -g playwright-core@1.59.1

WORKDIR /opt/telegram-claude
COPY . /opt/telegram-claude

RUN printf '%sudo ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/telegram-claude \
 && chmod 0440 /etc/sudoers.d/telegram-claude \
 && mkdir -p /tmp/.X11-unix \
 && chmod 1777 /tmp/.X11-unix \
 && if ! getent group 1000 >/dev/null; then groupadd --gid 1000 dashboard; fi \
 && if ! getent passwd 1000 >/dev/null; then useradd --uid 1000 --gid 1000 --groups sudo --create-home --shell /bin/bash dashboard; fi \
 && mkdir -p /home/dashboard \
 && chown -R 1000:1000 /home/dashboard /opt/telegram-claude

COPY docker/e2e/entrypoint.sh /usr/local/bin/telegram-claude-e2e-entrypoint
COPY docker/e2e/runtime.sh /usr/local/bin/telegram-claude-e2e-runtime
COPY docker/e2e/playwright-server.sh /usr/local/bin/telegram-claude-e2e-playwright
RUN chmod 0755 /usr/local/bin/telegram-claude-e2e-entrypoint /usr/local/bin/telegram-claude-e2e-runtime /usr/local/bin/telegram-claude-e2e-playwright

USER 1000:1000

EXPOSE 6080 5900 9222

CMD ["telegram-claude-e2e-entrypoint"]
