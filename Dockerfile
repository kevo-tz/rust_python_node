FROM rust:1.90.0-slim-bookworm

ENV LANG=C.UTF-8 \
    NODE_VERSION=24.9.0 \
    PYTHON_VERSION=3.13.7 \
    PATH=/usr/local/bin:$PATH \
    PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py \
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
    ca-certificates curl dirmngr xz-utils netbase tzdata git lld clang \
    # Python build dependencies
    dpkg-dev gcc gnupg libbluetooth-dev libbz2-dev libc6-dev libdb-dev \
    libexpat1-dev libffi-dev libgdbm-dev liblzma-dev libncursesw5-dev \
    libreadline-dev libsqlite3-dev libssl-dev make tk-dev uuid-dev zlib1g-dev; \
    \
    # Install Node.js
    curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"; \
    tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v$NODE_VERSION-linux-x64.tar.xz"; \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs; \
    \
    # Install Python from source
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
    nproc="$(nproc)"; \
    EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"; \
    LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"; \
    LDFLAGS="${LDFLAGS:--Wl},--strip-all"; \
    make -j "$nproc" \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
    "LDFLAGS=${LDFLAGS:-}" \
    "PROFILE_TASK=${PROFILE_TASK:-}"; \
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
    \) -exec rm -rf '{}' +; \
    ldconfig; \
    \
    # Create Python symlinks
    for src in idle3 pydoc3 python3 python3-config; do \
    dst="$(echo "$src" | tr -d 3)"; \
    if [ -s "/usr/local/bin/$src" ] && [ ! -e "/usr/local/bin/$dst" ]; then \
    ln -svT "$src" "/usr/local/bin/$dst"; \
    fi; \
    done; \
    \
    # Install pip
    curl -o get-pip.py "$PYTHON_GET_PIP_URL"; \
    python get-pip.py \
    --disable-pip-version-check \
    --no-cache-dir \
    --no-compile; \
    rm -f get-pip.py; \
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
    node --version; \
    python3 --version; \
    pip --version; \
    rustc --version
