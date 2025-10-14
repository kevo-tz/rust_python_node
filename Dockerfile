FROM rust:1.90.0-slim-trixie

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.10.0 \
    PYTHON_VERSION=3.13.8 \
    UV_INSTALL_SH=https://astral.sh/uv/install.sh \
    HOME="/home" \
    PYTHONDONTWRITEBYTECODE=1

# Install dependencies, Node.js, uv, and Python
RUN set -eux; \
    groupadd --gid 1000 node; \
    useradd --uid 1000 --gid node --shell /bin/bash --create-home node; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl dirmngr xz-utils netbase tzdata git lld clang; \
    \
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs; \
    \
    curl -LsSf $UV_INSTALL_SH | sh; \
    $HOME/.local/bin/uv python install $PYTHON_VERSION --default; \
    \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    \
    rustup component add clippy rustfmt; \
    rustc --version; \
    node --version; \
    $HOME/.local/bin/uv --version;

# Set working directory
WORKDIR /home/node/development

# Switch to non-root user
USER node