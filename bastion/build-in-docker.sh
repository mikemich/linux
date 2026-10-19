#!/bin/bash
# Run bastion/build.sh inside a Debian 13 container so any Linux host with
# Docker (or Podman via DOCKER=podman) can build the ISO. Arguments are passed
# through to build.sh, e.g.:
#
#   ./bastion/build-in-docker.sh --desktop
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-docker}"

# --privileged is required: live-build mounts proc/sys/dev inside its chroot.
exec "$DOCKER" run --rm --privileged \
	-v "$SRC:/src" -w /src \
	debian:trixie \
	./bastion/build.sh --install-deps "$@"
