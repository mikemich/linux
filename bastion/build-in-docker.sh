#!/bin/bash
# Run bastion/build.sh inside a Debian 13 container so any Linux host with
# Docker (or Podman via DOCKER=podman) can build the ISO. Arguments are passed
# through to build.sh, e.g.:
#
#   GITHUB_TOKEN=... BASTION_TOOLS_DIR=~/Documents/repos ./bastion/build-in-docker.sh --desktop
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-docker}"

extra=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
	extra+=(-e GITHUB_TOKEN)
fi
if [ -n "${BASTION_TOOLS_DIR:-}" ]; then
	extra+=(-v "$(realpath "$BASTION_TOOLS_DIR"):/tools:ro" -e BASTION_TOOLS_DIR=/tools)
fi

# --privileged is required: live-build mounts proc/sys/dev inside its chroot.
exec "$DOCKER" run --rm --privileged \
	-v "$SRC:/src" -w /src "${extra[@]}" \
	debian:trixie \
	./bastion/build.sh --install-deps "$@"
