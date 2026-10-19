#!/bin/bash
# Build the Bastion Linux live/installer ISO.
#
#   sudo ./bastion/build.sh [options]
#
# Options:
#   --kernel custom|stock  custom (default): build this tree with
#                          kernel/configs/bastion.config and ship it.
#                          stock: use Debian's signed kernel (Secure Boot,
#                          widest hardware support).
#   --desktop              add a minimal Xfce desktop + Wireshark GUI.
#   --jobs N               parallel kernel build jobs (default: nproc).
#   --install-deps         apt-get install the build dependencies first.
#   --out DIR              output directory (default: bastion/out).
#
# Must run as root on a Debian 13 (trixie) amd64 host, or anywhere via
# bastion/build-in-docker.sh.
set -euo pipefail

BASTION_VERSION="1.0"
BASTION_DIST="trixie"

KERNEL="custom"
DESKTOP=0
JOBS="$(nproc)"
INSTALL_DEPS=0
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$SRC/bastion/out"

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel) KERNEL="$2"; shift 2 ;;
	--desktop) DESKTOP=1; shift ;;
	--jobs) JOBS="$2"; shift 2 ;;
	--install-deps) INSTALL_DEPS=1; shift ;;
	--out) OUT="$(realpath -m "$2")"; shift 2 ;;
	-h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (live-build needs chroot and mounts)"
[ "$(uname -m)" = "x86_64" ] || die "only x86_64 hosts are supported"
case "$KERNEL" in custom|stock) ;; *) die "--kernel must be custom or stock" ;; esac

if [ "$INSTALL_DEPS" -eq 1 ]; then
	log "Installing build dependencies"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends \
		live-build debootstrap ca-certificates curl \
		build-essential bc bison flex kmod cpio rsync python3 git \
		libelf-dev libdw-dev libssl-dev dwarves dpkg-dev debhelper
fi

command -v lb >/dev/null || die "live-build not installed (use --install-deps)"
if ! grep -qs '^ID=debian' /etc/os-release; then
	echo "warning: non-Debian host; if lb fails use bastion/build-in-docker.sh" >&2
fi

mkdir -p "$OUT"
FLAVOUR="amd64"
SECURE_BOOT="auto"

if [ "$KERNEL" = "custom" ]; then
	KOUT="$OUT/kernel/build"
	mkdir -p "$KOUT"
	log "Configuring kernel (x86_64_defconfig + hardening + bastion)"
	make -C "$SRC" O="$KOUT" LOCALVERSION= \
		x86_64_defconfig hardening.config bastion.config
	KVER="$(make -s -C "$SRC" O="$KOUT" LOCALVERSION= kernelrelease)"
	log "Building kernel $KVER packages with $JOBS jobs"
	rm -f "$OUT"/kernel/linux-*.deb
	make -C "$SRC" O="$KOUT" LOCALVERSION= -j"$JOBS" bindeb-pkg \
		KDEB_PKGVERSION="$BASTION_VERSION-1"
	FLAVOUR="$KVER"
	# Our kernel is not signed by Debian, so shim would refuse it anyway.
	SECURE_BOOT="disable"
fi

LIVE="$OUT/live"
log "Preparing live-build tree in $LIVE"
if [ -d "$LIVE" ]; then
	(cd "$LIVE" && lb clean --purge) || true
	rm -rf "$LIVE"
fi
cp -a "$SRC/bastion/live" "$LIVE"
rm -rf "$LIVE/optional"
# Read by chroot hooks via /live-build/config.
echo "BASTION_VERSION=$BASTION_VERSION" > "$LIVE/config/bastion.env"
if [ "$DESKTOP" -eq 1 ]; then
	cp "$SRC/bastion/live/optional/desktop.list.chroot" \
		"$LIVE/config/package-lists/bastion-desktop.list.chroot"
fi
if [ "$KERNEL" = "custom" ]; then
	mkdir -p "$LIVE/config/packages.chroot"
	cp "$OUT/kernel/linux-image-${KVER}_"*.deb "$LIVE/config/packages.chroot/"
fi

export BASTION_VERSION BASTION_DIST
export BASTION_KERNEL_FLAVOUR="$FLAVOUR" BASTION_SECURE_BOOT="$SECURE_BOOT"

cd "$LIVE"
log "Running lb config"
lb config
log "Running lb build (this downloads ~1 GB of packages)"
lb build 2>&1 | tee "$OUT/live-build.log"

ISO="$(ls -1 "$LIVE"/*.iso 2>/dev/null | head -n1)"
[ -n "$ISO" ] || die "live-build did not produce an ISO; see $OUT/live-build.log"
NAME="bastion-$BASTION_VERSION-amd64"
[ "$DESKTOP" -eq 1 ] && NAME="$NAME-desktop"
mv "$ISO" "$OUT/$NAME.iso"
(cd "$OUT" && sha256sum "$NAME.iso" > "$NAME.iso.sha256")
log "Done: $OUT/$NAME.iso ($(du -h "$OUT/$NAME.iso" | cut -f1))"
