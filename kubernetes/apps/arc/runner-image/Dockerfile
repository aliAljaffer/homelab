ARG BASE_IMAGE=harbor.alialjaffer.com/mirror/actions-runner@sha256:0ce3288e48b012a83685998f683a2ae0cbd284fa722c090dda0af5443215cf30
FROM ${BASE_IMAGE}

USER root

ARG GO_VERSION=1.27.3
ARG NODE_VERSION=22.23.4
ARG GH_VERSION=2.103.3

LABEL org.opencontainers.image.title="homelab ARC toolchain" \
      org.opencontainers.image.description="actions-runner with Go, Node, Python, gcc, Playwright and gh" \
      io.homelab.toolchain.go="${GO_VERSION}" \
      io.homelab.toolchain.node="${NODE_VERSION}" \
      io.homelab.toolchain.gh="${GH_VERSION}"

ENV GOPATH=/home/runner/go \
    GOMODCACHE=/home/runner/go/pkg/mod \
    PLAYWRIGHT_BROWSERS_PATH=/home/runner/.cache/ms-playwright \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# gcc/libc6-dev for cgo (-race), python3 for scripts, and the electron-builder
# Linux packaging tools used by fai's release workflow.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev make pkg-config python3 python3-venv ca-certificates curl xz-utils \
      fakeroot rpm libarchive-tools openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz

RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz \
    && tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz \
    && rm /tmp/node.tar.xz

ENV PATH=/usr/local/go/bin:/usr/local/bin:$PATH

RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -o /tmp/gh.tgz \
    && tar -C /tmp -xzf /tmp/gh.tgz \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_amd64"

COPY go/grooszy/go.mod go/grooszy/go.sum /tmp/go-cache/grooszy/
COPY go/chat/go.mod go/chat/go.sum /tmp/go-cache/chat/
COPY go/fai/go.mod go/fai/go.sum /tmp/go-cache/fai/
RUN cd /tmp/go-cache/grooszy && go mod download \
    && cd /tmp/go-cache/chat && go mod download \
    && cd /tmp/go-cache/fai && go mod download \
    && rm -rf /tmp/go-cache

COPY root/package.json root/package-lock.json /tmp/npm-root/
COPY web/package.json web/package-lock.json /tmp/npm-web/
COPY fai/frontend/package.json fai/frontend/package-lock.json /tmp/npm-fai/
RUN cd /tmp/npm-root && npm ci --cache /home/runner/.npm --no-audit --no-fund \
    && npx playwright install --with-deps chromium \
    && cd /tmp/npm-web && npm ci --cache /home/runner/.npm --no-audit --no-fund \
    && cd /tmp/npm-fai && npm ci --cache /home/runner/.npm --no-audit --no-fund \
    && rm -rf /tmp/npm-root /tmp/npm-web /tmp/npm-fai

RUN chown -R runner:docker /home/runner/go /home/runner/.npm /home/runner/.cache \
    && mkdir -p /opt/hostedtoolcache \
    && chown runner:docker /opt/hostedtoolcache

USER runner
