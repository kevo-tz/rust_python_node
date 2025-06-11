FROM rust:1.87.0-slim-bookworm

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.2.0 \
    PYTHON_VERSION=3.13.4 \
    PATH=/usr/local/bin:$PATH \
    PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py

# Install system dependencies, Node.js, and create user
RUN set -eux; \
    groupadd --gid 1000 node; \
    useradd --uid 1000 --gid node --shell /bin/bash --create-home node; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dirmngr \
        xz-utils \
        netbase \
        tzdata \
        git; \
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs; \
    node --version; \
    rm -rf /var/lib/apt/lists/*

# Install Python build dependencies and build Python from source
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        dpkg-dev \
        gcc \
        gnupg \
        libbluetooth-dev \
        libbz2-dev \
        libc6-dev \
        libdb-dev \
        libexpat1-dev \
        libffi-dev \
        libgdbm-dev \
        liblzma-dev \
        libncursesw5-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        make \
        tk-dev \
        uuid-dev \
        xz-utils \
        zlib1g-dev; \
    curl -o python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz"; \
    mkdir -p /usr/src/python; \
    tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz; \
    rm python.tar.xz; \
    cd /usr/src/python; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    ./configure \
        --build="$gnuArch" \
        --enable-loadable-sqlite-extensions \
        --enable-optimizations \
        --enable-option-checking=fatal \
        --enable-shared \
        --with-lto \
        --with-system-expat \
        --without-ensurepip; \
    make -j"$(nproc)"; \
    rm python; \
    make -j"$(nproc)" python "LDFLAGS=-Wl,-rpath='\$\$ORIGIN/../lib'"; \
    make install; \
    cd /; \
    rm -rf /usr/src/python; \
    find /usr/local -depth \( \
        \( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
        -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
    \) -exec rm -rf '{}' +; \
    ldconfig; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/*; \
    python3 --version

# Create symlinks for python tools
RUN set -eux; \
    for src in idle3 pydoc3 python3 python3-config; do \
        dst="$(echo "$src" | tr -d 3)"; \
        [ -s "/usr/local/bin/$src" ]; \
        [ ! -e "/usr/local/bin/$dst" ]; \
        ln -svT "$src" "/usr/local/bin/$dst"; \
    done

# Install pip
RUN set -eux; \
    curl -o get-pip.py "$PYTHON_GET_PIP_URL"; \
    python get-pip.py --disable-pip-version-check --no-cache-dir --no-compile; \
    rm -f get-pip.py; \
    pip --version

# Install Rust components
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends clang lld pkg-config libssl-dev; \
    rustup component add clippy rustfmt; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/*

# Set default user
USER node

# Set working directory
WORKDIR /home/node

# Default command
CMD ["bash"]
