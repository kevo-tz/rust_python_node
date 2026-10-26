# Rust Python Node
A Docker image with Rust, Python (via uv), and Node.js for multi-language development.

- Slim Trixie Image
- Rust Version 1.99.1
- Node Version 26.12.1
- Python Version 3.15.1
- UV Version 0.13.5


# Usage
Pull the latest image from Docker Hub

```bash
docker pull kevotz/rust_python_node
```

## Tags

| Tag | Description |
| --- | --- |
| `latest` | Most recent build |
| `main` | Most recent build from the `main` branch |
| `rpn-YYYYMMDD-HHMMSS` | Immutable timestamped snapshot of a build (UTC); the 10 most recent are kept |
| `sha-<short-sha>` | Build produced from a specific commit |
| `v<rust>-node<node>-py<python>-uv<uv>` | Exact toolchain versions |

Pin an exact toolchain when reproducibility matters:

```bash
docker pull kevotz/rust_python_node:v1.99.1-node26.12.1-py3.15.1-uv0.13.5
```

The toolchain tag is rebuilt by the weekly job, so its contents can move with base-image and apt updates. Pin a digest (`image@sha256:...`) when the exact bytes matter.

The image is published for `linux/amd64` and `linux/arm64`.

# Contributing
Contributions are welcome! Open an issue or a pull request.

# License
This project is licensed under the MIT License.
