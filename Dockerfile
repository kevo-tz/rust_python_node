FROM rust:1.73-slim-bookworm

ENV PYTHON_VERSION 3.11.6
ENV NODE_VERSION 21.1.0
ENV ARCH x64

# Rust Base Image
RUN set -ex \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends libssl-dev libbluetooth-dev tk-dev uuid-dev clang lld curl \
    # install rust toochain
    && rustup component add clippy rustfmt \
    # install Node
    && curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$ARCH.tar.xz" \
    && tar -xJf "node-v$NODE_VERSION-linux-$ARCH.tar.xz" -C /usr/local --strip-components=1 --no-same-owner \
    && rm "node-v$NODE_VERSION-linux-$ARCH.tar.xz" \
    && ln -s /usr/local/bin/node /usr/local/bin/nodejs \
    # install Python
    && curl -fsSLO --compressed "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz" \
    && mkdir -p /usr/src/python \
    && tar --extract --directory /usr/src/python --strip-components=1 --file "Python-$PYTHON_VERSION.tar.xz" \
    && rm "Python-$PYTHON_VERSION.tar.xz" \
    && cd /usr/src/python \
    && ./configure --enable-loadable-sqlite-extensions --enable-optimizations --without-ensurepip \
    && make \
    && make install \
    # install pip
    && curl -fsSLO --compressed "https://bootstrap.pypa.io/get-pip.py" \
    && export PYTHONDONTWRITEBYTECODE=1 \
    && python3 get-pip.py \
    && rm get-pip.py \
    # clean up
    && cd / \
    && rm -rf /usr/src/python \
    && apt-get autoremove -y && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# make some useful symlinks that are expected to exist ("/usr/local/bin/python" and friends)
RUN set -eux; \
    for src in idle3 pydoc3 python3 python3-config; do \
    dst="$(echo "$src" | tr -d 3)"; \
    [ -s "/usr/local/bin/$src" ]; \
    [ ! -e "/usr/local/bin/$dst" ]; \
    ln -svT "$src" "/usr/local/bin/$dst"; \
    done
