FROM rust:1.87.0-slim-bookworm

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.3.0 \
    PYTHON_VERSION=3.13.5 \
    PATH=/usr/local/bin:$PATH \
    PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py

# Base dependencies (shared)
RUN set -eux; \
    # Install Rust tools and build deps
    rustup component add clippy rustfmt; \
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
    # install nodejs
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    apt-mark auto '.*' > /dev/null; \
    find /usr/local -type f -executable -exec ldd '{}' ';' \
    | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
    | sort -u \
    | xargs -r dpkg-query --search \
    | cut -d: -f1 \
    | sort -u \
    | xargs -r apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
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
    --build="$gnuArch" \
    --enable-loadable-sqlite-extensions \
    --enable-optimizations \
    --enable-option-checking=fatal \
    --enable-shared \
    --with-lto \
    --with-system-expat \
    --without-ensurepip; \
    nproc="$(nproc)"; \
    EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"; \
    LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"; \
    LDFLAGS="${LDFLAGS:--Wl},--strip-all"; \
    make -j "$nproc" \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
    "LDFLAGS=${LDFLAGS:-}" \
    "PROFILE_TASK=${PROFILE_TASK:-}"; \
    # https://github.com/docker-library/python/issues/784
    # prevent accidental usage of a system installed libpython of the same version
    rm python; \
    make -j "$nproc" \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
    "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
    "PROFILE_TASK=${PROFILE_TASK:-}" \
    python; \
    make install; \
    cd /; \
    rm -rf /usr/src/python; \
    find /usr/local -depth \
    \( \
    \( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
    -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
    \) -exec rm -rf '{}' + ; \
    ldconfig; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
    | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
    | sort -u \
    | xargs -r dpkg-query --search \
    | cut -d: -f1 \
    | sort -u \
    | xargs -r apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
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
