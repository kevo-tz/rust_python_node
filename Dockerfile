FROM rust:1.87.0-slim-bookworm

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.2.0 \
    PYTHON_VERSION=3.13.4 \
    PATH=/usr/local/bin:$PATH \
    PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py

# Base dependencies (shared)
RUN set -eux; \
    # Create node user early for consistency
    groupadd --gid 1000 node; \
    useradd --uid 1000 --gid node --shell /bin/bash --create-home node; \
    apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    dirmngr \
    xz-utils \
    gnupg \
    git \
    netbase \
    tzdata \
    clang \
    lld \
    pkg-config \
    libssl-dev; \
    rm -rf /var/lib/apt/lists/*; \
    # Install Rust tools and build deps
    rustup component add clippy rustfmt

# Install Node.js
RUN set -eux; \
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs; \
    node --version

# Install Python
RUN set -eux; \
    buildDeps="dpkg-dev gcc make libbluetooth-dev libbz2-dev libc6-dev libdb-dev libexpat1-dev libffi-dev \
    libgdbm-dev liblzma-dev libncursesw5-dev libreadline-dev libsqlite3-dev libssl-dev tk-dev uuid-dev zlib1g-dev"; \
    apt-get update && apt-get install -y --no-install-recommends $buildDeps; \
    curl -o python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz"; \
    mkdir -p /usr/src/python; \
    tar -xf python.tar.xz -C /usr/src/python --strip-components=1; \
    rm python.tar.xz; \
    cd /usr/src/python; \
    ./configure \
    --enable-optimizations \
    --with-lto \
    --enable-shared \
    --with-system-expat \
    --without-ensurepip \
    --enable-loadable-sqlite-extensions; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /usr/src/python; \
    ldconfig; \
    apt-get purge -y --auto-remove $buildDeps; \
    rm -rf /var/lib/apt/lists/*; \
    python3 --version

# make some useful symlinks that are expected to exist ("/usr/local/bin/python" and friends)
RUN set -eux; \
    for src in idle3 pydoc3 python3 python3-config; do \
    dst="$(echo "$src" | tr -d 3)"; \
    [ -s "/usr/local/bin/$src" ]; \
    [ ! -e "/usr/local/bin/$dst" ]; \
    ln -svT "$src" "/usr/local/bin/$dst"; \
    done

# Install pip
RUN set -eux; \
    curl -sSL "$PYTHON_GET_PIP_URL" -o get-pip.py; \
    python get-pip.py --disable-pip-version-check --no-cache-dir --no-compile; \
    rm get-pip.py; \
    pip --version
