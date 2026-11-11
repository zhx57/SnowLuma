# syntax=docker/dockerfile:1.7

# SnowLuma all-in-one image: Linux QQ + Xvfb + VNC/noVNC + supervisord + SnowLuma.
#
# The build is split so the heavy Chromium-backed QQ layer is cached
# independently from the SnowLuma bundle: changing TypeScript sources only
# rebuilds the last stage.

ARG NODE_VERSION=24.22.2

# ---------------------------------------------------------------------------
# Stage 1: build the SnowLuma release bundle (dist/) from source.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS builder

ENV PNPM_HOME=/pnpm
ENV PATH="${PNPM_HOME}:${PATH}"
ENV CI=1

RUN corepack enable && corepack prepare pnpm@11.25.0 --activate

WORKDIR /src

# Dependency manifests first so the install layer survives source edits.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/common/package.json packages/common/
COPY packages/bridge/package.json packages/bridge/
COPY packages/core/package.json packages/core/
COPY packages/mcp/package.json packages/mcp/
COPY packages/onebot/package.json packages/onebot/
COPY packages/proto-defs/package.json packages/proto-defs/
COPY packages/protocol/package.json packages/protocol/
COPY packages/proton/package.json packages/proton/
COPY packages/runtime/package.json packages/runtime/
COPY packages/sdk/package.json packages/sdk/
COPY packages/sqlite/package.json packages/sqlite/
COPY packages/ui/package.json packages/ui/
COPY packages/webui/package.json packages/webui/
COPY packages/websocket/package.json packages/websocket/

RUN pnpm install --frozen-lockfile

COPY . .

# Inject the QQ hook addon's file capability so the unprivileged runtime user
# can ptrace a QQ process it did not start, without relaxing host sysctls.
ARG TARGETARCH
# buildx reports amd64/arm64; the release bundler uses x64/arm64.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) target=linux-x64 ;; \
      arm64) target=linux-arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    SNOWLUMA_TARGET="${target}" pnpm run build:all; \
    node tools/check-release-layout.mjs dist

# ---------------------------------------------------------------------------
# Stage 2: Linux QQ runtime layer (Chromium + Qt, rarely changes).
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS runtime

ARG TARGETARCH
ARG QQ_VERSION=3.2.32
ARG QQ_BUILD=260812
ARG QQ_RELEASE=qq-packages-20260813-1d08f1d4

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# QQ ships as a Qt/Chromium desktop app; Xvfb + a window manager + VNC are what
# make it usable headlessly for the initial QR-code login.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      xz-utils \
      libcap2-bin \
      procps \
      tini \
      supervisor \
      dbus-x11 \
      xvfb \
      x11-utils \
      x11vnc \
      fluxbox \
      novnc \
      websockify \
      fonts-noto-cjk \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libatspi2.0-0 \
      libcairo2 \
      libcups2 \
      libdbus-1-3 \
      libdrm2 \
      libgbm1 \
      libglib2.0-0 \
      libgtk-3-0 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxshmfence1 \
 && rm -rf /var/lib/apt/lists/*

# Linux QQ is only distributed through a JS-rendered download page whose CDN
# rejects non-browser user agents, so pin a known-good mirror of the official
# package instead of scraping the download config at build time.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) qq_arch=amd64 ;; \
      arm64) qq_arch=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/Rodert/qq-versions/releases/download/${QQ_RELEASE}/QQ_${QQ_VERSION}_${QQ_BUILD}_${qq_arch}_01.deb"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/qq.deb "${url}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/qq.deb; \
    rm -f /tmp/qq.deb; \
    rm -rf /var/lib/apt/lists/*

# The hook addon injects via ptrace. Granting the interpreter the capability
# lets the non-root runtime user inject inside the container's capability
# boundary; the container still needs --cap-add=SYS_PTRACE to use it.
RUN set -eux; \
    node_bin="$(command -v node)"; \
    setcap cap_sys_ptrace+ep "${node_bin}"; \
    getcap "${node_bin}"

# ---------------------------------------------------------------------------
# Stage 3: final assembly.
# ---------------------------------------------------------------------------
FROM runtime AS final

ENV SNOWLUMA_HOME=/app
ENV SNOWLUMA_UID=1000
ENV SNOWLUMA_GID=1000
ENV SNOWLUMA_WEBUI_HOST=0.0.0.0
ENV SNOWLUMA_WEBUI_PORT=5099
ENV SNOWLUMA_HOOK_AUTOLOAD=1
ENV SNOWLUMA_SCREEN=1920x1080x24
ENV SNOWLUMA_QQ_FLAGS="--disable-gpu --disable-software-rasterizer --disable-gpu-compositing"
ENV SNOWLUMA_EXTRA_QQ_HOMES=
ENV DISPLAY=:1

WORKDIR /app

COPY --from=builder /src/dist/ /app/
COPY docker/rootfs/ /

RUN set -eux; \
    chmod +x /app/launcher.sh /usr/local/bin/snowluma-entrypoint /usr/local/bin/snowluma-qq-launch; \
    mkdir -p /app/data /app/.config /app/.local/share /app/logs; \
    ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 6081 noVNC, 5099 WebUI, 3000 OneBot HTTP, 3001 OneBot WebSocket.
EXPOSE 6081 5099 3000 3001

VOLUME ["/app/data", "/app/.config", "/app/.local/share"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${SNOWLUMA_WEBUI_PORT}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/snowluma-entrypoint"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
