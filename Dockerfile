FROM rust:1.90.0-slim-bookworm

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.10.0 \
    PYTHON_VERSION=3.13.8 \
    UV_INSTALL_SH=https://astral.sh/uv/install.sh \
    HOME="/home" \
    PYTHONDONTWRITEBYTECODE=1

RUN set -eux; \
    # Create a non-root user
    groupadd --gid 1000 node; \
    useradd --uid 1000 --gid node --shell /bin/bash --create-home node; \
    \
    # Save manually installed packages
    savedAptMark="$(apt-mark showmanual)"; \
    \
    # Install build-time and runtime dependencies
    apt-get update; \
    apt-get install -y --no-install-recommends \
    # General dependencies
    ca-certificates curl dirmngr xz-utils netbase tzdata git lld clang; \
    \
    # Install Node.js
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs; \
    \
    # Install uv (Astral)
    curl -LsSf https://astral.sh/uv/install.sh | sh; \
    \
    # Install Python
    $HOME/.local/bin/uv python install $PYTHON_VERSION --default; \
    \
    # Clean up build dependencies and apt cache
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # Install Rust components
    rustup component add clippy rustfmt; \
    \
    # Verify installations
    rustc --version; \
    node --version; \
    $HOME/.local/bin/uv --version; \
