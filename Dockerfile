# Stage 1: Builder
FROM rust:1.90.0-slim-trixie AS builder

# Set build arguments for versions
ARG NODE_VERSION=24.10.0
ARG PYTHON_VERSION=3.13.8
ARG UV_VERSION=0.9.3

# Set environment variables
ENV HOME="/home"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install dependencies, Node.js, uv, and Python
RUN set -eux; \
    # Update and install required packages
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl dirmngr xz-utils netbase tzdata git lld clang; \
    \
    # Install Node.js
    curl -fsSLO --compressed "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    \
    # Install uv
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh; \
    \
    # Install Python via uv
    $HOME/.local/bin/uv python install $PYTHON_VERSION --default; \
    \
    # Clean up
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Stage 2: Final
FROM rust:1.90.0-slim-trixie

LABEL maintainer="Kevo <me@kevo.co.tz>" \
      version="1.0" \
      description="Docker image for Rust, Node.js, Python, and Uv Project Development"

# Set environment variables
ENV PATH=/home/.local/bin:$PATH \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=Etc/UTC

# Copy Node.js, npm, npx, and uv from the builder stage
COPY --from=builder /usr/local/bin/node /usr/local/bin/node
COPY --from=builder /usr/local/bin/npm /usr/local/bin/npm
COPY --from=builder /usr/local/bin/npx /usr/local/bin/npx
COPY --from=builder /home/.local /home/.local

# Install runtime dependencies
RUN set -eux; \
    groupadd --gid 1000 project_user; \
    useradd --uid 1000 --gid project_user --shell /bin/bash --create-home project; \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl dirmngr xz-utils netbase git; \
    \
    # Clean up
    rm -rf /var/lib/apt/lists/*; \
    \
    # Symlink nodejs to node
    ln -s /usr/local/bin/node /usr/local/bin/nodejs

# Set a default working directory
WORKDIR /project

CMD ["bash"]