ARG RUST_VERSION=1.99.1
ARG NODE_VERSION=26.12.1
ARG PYTHON_VERSION=3.15.1
ARG UV_VERSION=0.13.5

# stage 1: Python via uv on the Rust base
FROM rust:${RUST_VERSION}-slim-trixie AS uv-base
ARG UV_VERSION
ARG PYTHON_VERSION
ENV HOME="/home"
ENV UV_HOME=$HOME/.local/
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV TZ=Etc/UTC
RUN set -euxo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    rm -rf /var/lib/apt/lists/*; \
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh; \
    $UV_HOME/bin/uv python install "${PYTHON_VERSION}" --default

# stage 2: Node.js source image
# COPY --from does not expand ARG values, so this stage exists to make the
# Node version an ARG without breaking the copy in the final stage.
FROM node:${NODE_VERSION}-trixie-slim AS node-base

# stage 3: final image with Rust, Python via uv and Node.js
FROM rust:${RUST_VERSION}-slim-trixie
ARG IMAGE_VERSION=dev
LABEL maintainer="Kevo <me@kevo.co.tz>" \
      version="${IMAGE_VERSION}" \
      description="Docker image for Rust, Node.js, Python, and Uv Project Development"
ENV HOME="/home"
# UV_HOME is the install/copy path used by the uv-base stage, not a uv setting.
ENV UV_HOME=/home/.local/
ENV PATH=/home/.local/bin:$PATH
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV LANG=C.UTF-8
ENV TZ=Etc/UTC
COPY --from=uv-base /home/.local /home/.local
COPY --from=node-base /usr/local /usr/local

# Install Rust components before the cache-busted apt layer so weekly rebuilds
# do not redo this work.
RUN set -euxo pipefail; \
    rustup component add rustfmt clippy rust-analyzer

# APT_CACHE_BUST must be declared in this stage: a global ARG before FROM is
# not visible here. Scheduled runs pass github.run_id so the layer is rebuilt
# and apt actually refreshes; every other event passes 0 and reuses the cache.
ARG APT_CACHE_BUST=0
RUN set -euxo pipefail; \
    echo "apt cache bust: ${APT_CACHE_BUST}"; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        pkg-config \
        libssl-dev \
        zlib1g-dev \
        openssh-client \
        jq \
        less \
        unzip \
        vim-tiny; \
    rm -rf /var/lib/apt/lists/*; \
    install -d /etc/rpn; \
    printf '%s\n' "${APT_CACHE_BUST}" > /etc/rpn/apt-cache-bust; \
    printf '%s\n' 'export PATH="/home/.local/bin:/usr/local/cargo/bin:$PATH"' > /etc/profile.d/00-toolchain-path.sh; \
    chmod 0644 /etc/profile.d/00-toolchain-path.sh

WORKDIR /workspace
CMD ["bash"]
