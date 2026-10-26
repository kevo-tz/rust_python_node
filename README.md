# Rust Python Node
A multi-language project that combines Rust, Python with UV, and Node.js to demonstrate interoperability between these languages.

- Slim Trixie Image
- Rust Version 1.99.1
- Node Version 26.12.1
- Python Version 3.15.2
- UV Version 0.13.5


# Usage 
Pull the latest image from the Docker

`
docker pull kevotz/rust_python_node
`

## Tags

| Tag | Description |
| --- | --- |
| `latest` | Most recent build |
| `main` | Most recent build from the `main` branch |
| `rpn-YYYYMMDD-HHMMSS` | Immutable timestamped snapshot of a build (UTC) |
| `sha-<short-sha>` | Build produced from a specific commit |
| `v<rust>-node<node>-py<python>-uv<uv>` | Exact toolchain versions |

Pin an exact toolchain when reproducibility matters:

`
docker pull kevotz/rust_python_node:v1.99.1-node26.12.1-py3.15.2-uv0.13.5
`

The image is published for `linux/amd64` and `linux/arm64`.

# Contributing
Contributions are welcome! I'd like you to please follow our contribution guidelines.

# License
This project is licensed under the MIT License.
