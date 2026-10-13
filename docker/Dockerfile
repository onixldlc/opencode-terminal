ARG TARGETARCH

# the retry proxy is a static Go binary, built once here and copied in. no Go
# runtime, no node_modules and no python deps end up in the final image.
FROM docker.io/library/golang:1.23-bookworm AS proxy-build
WORKDIR /src
COPY docker/proxy/go.mod ./
COPY docker/proxy/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/oc-retry-proxy .

FROM docker.io/library/node:22-bookworm-slim
ARG TARGETARCH

# base deps
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-${TARGETARCH} \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates ripgrep wget curl less git fzf unzip

# python
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-${TARGETARCH} \
    apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python3-dev

# go
ARG GO_VERSION=1.26.2
RUN wget -q https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz \
    && tar -C /usr/local -xzf go${GO_VERSION}.linux-${TARGETARCH}.tar.gz \
    && rm go${GO_VERSION}.linux-${TARGETARCH}.tar.gz

# java
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-${TARGETARCH} \
    apt-get update && apt-get install -y --no-install-recommends \
        default-jre-headless

# sudo (passwordless for dev)
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-${TARGETARCH} \
    apt-get update && apt-get install -y --no-install-recommends sudo \
 && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev

# install opencode globally. the npm package is a shim: its postinstall pulls the
# platform binary from the opencode-<os>-<arch> optional dep, so --ignore-scripts
# would leave a stub behind.
ARG OPENCODE_VERSION=1.19.0
RUN npm install -g opencode-ai@${OPENCODE_VERSION}

# retries are handled by the proxy, not by opencode: its own schedule (5 attempts,
# ~1 min) is hardcoded in the bun executable with no config key and no plugin hook.
COPY --from=proxy-build /out/oc-retry-proxy /usr/local/bin/oc-retry-proxy

# seeds copied into the mounted config dir on first run by the entrypoint
COPY docker/opencode.default.jsonc /opt/opencode/opencode.default.jsonc
COPY docker/AGENTS.default.md /opt/opencode/AGENTS.default.md
COPY docker/cli.default.json /opt/opencode/cli.default.json
COPY docker/retry.default.json /opt/opencode/retry.default.json
COPY docker/plugins/retry.ts /opt/opencode/plugins/retry.ts
COPY docker/entrypoint.sh /usr/local/bin/opencode-entrypoint.sh
COPY docker/verify.sh /usr/local/bin/opencode-verify.sh
RUN chmod 755 /usr/local/bin/opencode-entrypoint.sh /usr/local/bin/opencode-verify.sh

# match host user. pass at build: --build-arg UID=$(id -u) --build-arg GID=$(id -g)
ARG UID=1000
ARG GID=1000

# nuke existing 'node' user (UID 1000) to avoid collision, then create 'dev' at host UID
ENV HOME=/home/dev
RUN userdel -r node 2>/dev/null || true \
 && (getent group $GID >/dev/null || groupadd -g $GID dev) \
 && useradd -m -u $UID -g $GID -d $HOME -s /bin/bash dev \
 && mkdir -p $HOME/work \
 && chown -R $UID:$GID $HOME

# Pre-create the XDG tree dev-owned. The CLI bind-mounts .config/opencode and
# .local/share/opencode; if their parents are missing, podman creates the whole
# chain as root and then dev can't write siblings like .local/state — opencode
# dies with EACCES on mkdir '/home/dev/.local/state'.
RUN mkdir -p $HOME/.config/opencode $HOME/.local/share/opencode $HOME/.local/state $HOME/.cache \
 && chown -R $UID:$GID $HOME/.config $HOME/.local $HOME/.cache

USER dev
WORKDIR $HOME/work

ENV PATH="/usr/local/go/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
ENV GOPATH="$HOME/go"

# rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --default-toolchain stable --profile minimal

# default model when the config dir is seeded for the first time. switch to a
# zai-coding-plan/* id if you pay for the GLM Coding Plan instead of the API.
ENV OPENCODE_DEFAULT_MODEL="zai/glm-5.3"

# default retry policy for the proxy. the seeded plugin can override any of it
# per session (and per provider) without a restart; these are the fallback for
# requests that arrive without the plugin's header.
ENV OC_RETRY_MAX="200"
ENV OC_RETRY_CAP="60000"
ENV OC_RETRY_BASE="2000"
ENV OC_RETRY_DEADLINE="3h"

ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]
