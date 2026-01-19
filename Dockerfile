ARG RUST_VERSION=1.92.0
ARG NODE_VERSION=25.3.0
ARG PYTHON_VERSION=3.14.2
ARG UV_VERSION=0.9.24

# stage 1: Base image Rust with Python via UV
FROM rust:${RUST_VERSION}-slim-trixie AS uv-base
ARG UV_VERSION
ARG PYTHON_VERSION
ENV HOME="/home"
ENV UV_HOME=$HOME/.local/
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV TZ=Etc/UTC
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends curl; \
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh; \
    $UV_HOME/bin/uv python install "${PYTHON_VERSION}" --default;

# stage 2: Base image Node.js
FROM node:${NODE_VERSION}-trixie-slim AS node-base
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y;

# stage 3: Final image with Rust, Python via UV and Node.js
FROM rust:${RUST_VERSION}-slim-trixie
LABEL maintainer="Kevo <me@kevo.co.tz>" \
      version="1.0" \
      description="Docker image for Rust, Node.js, Python, and Uv Project Development"
ENV HOME="/home"
ENV UV_HOME=$HOME/.local/
ENV PATH=$UV_HOME/bin:$PATH
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV LANG=C.UTF-8
ENV TZ=Etc/UTC
COPY --from=uv-base $UV_HOME $UV_HOME
COPY --from=node-base /usr/local /usr/local
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ca-certificates curl git; \
    rm -rf /var/lib/apt/lists/*; \
    rustup component add rustfmt clippy rust-analyzer;
CMD ["bash"]