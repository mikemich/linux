#!/bin/bash
# Fetch and build the tools in bastion/tools.list, and stage them as a root
# filesystem overlay for the image:
#
#   ./bastion/build-tools.sh OUTDIR      -> OUTDIR/tools/stage/
#
# Environment:
#   BASTION_TOOLS_DIR  folder holding local checkouts (e.g. ~/Documents/repos);
#                      a folder named like a tool is used instead of cloning
#   GITHUB_TOKEN       token for cloning private GitHub repositories
#
# Needs git, rsync, cargo, libpcap-dev, and node/npm for Spctr's web UI.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$SRC/bastion/tools.list"
OUT="$(realpath -m "${1:?usage: build-tools.sh OUTDIR}")"
WORK="$OUT/tools"
STAGE="$WORK/stage"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }

git_auth() {
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		local basic
		basic="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
		git -c "http.https://github.com/.extraheader=Authorization: Basic $basic" "$@"
	else
		git "$@"
	fi
}

# Print the source folder for a tool, cloning or updating it if needed.
fetch() {
	local name="$1" source="$2" dir
	if [ -n "${BASTION_TOOLS_DIR:-}" ]; then
		dir="$(find "$BASTION_TOOLS_DIR/" -mindepth 1 -maxdepth 1 \
			-iname "$name" -print -quit 2>/dev/null)"
		if [ -n "$dir" ] && [ -d "$dir" ]; then
			echo "$dir"
			return 0
		fi
	fi
	[ "$source" = local ] && return 1
	dir="$WORK/src/$name"
	if [ -d "$dir/.git" ]; then
		git_auth -C "$dir" pull -q --ff-only >&2 || return 1
	else
		rm -rf "$dir"
		git_auth clone -q --depth 1 "$source" "$dir" >&2 || return 1
	fi
	echo "$dir"
}

build_python() {
	local name="$1" dir="$2"
	mkdir -p "$STAGE/opt/bastion-tools/src"
	rsync -a --delete --exclude .git --exclude .venv --exclude '__pycache__' \
		--exclude tests "$dir/" "$STAGE/opt/bastion-tools/src/$name/"
	echo "$name" >> "$STAGE/opt/bastion-tools/python.order"
}

build_cargo() {
	local name="$1" dir="$2" bins="${3:-$1}" bin
	CARGO_TARGET_DIR="$WORK/target/$name" \
		cargo build --release --locked --manifest-path "$dir/Cargo.toml"
	mkdir -p "$STAGE/usr/local/bin"
	for bin in ${bins//,/ }; do
		install -m 755 "$WORK/target/$name/release/$bin" "$STAGE/usr/local/bin/$bin"
	done
}

build_spctr() {
	# Build from a scratch copy: the UI build writes into the tree, and local
	# checkouts may be read-only (as in build-in-docker.sh).
	local dir="$WORK/build/spctr"
	mkdir -p "$dir"
	rsync -a --delete --exclude .git --exclude node_modules --exclude target \
		--exclude dist "$1/" "$dir/"
	(cd "$dir/spectre-ui" && npm ci --no-audit --no-fund --loglevel=error && npm run build)
	CARGO_TARGET_DIR="$WORK/target/spctr" \
		cargo build --release --locked --manifest-path "$dir/Cargo.toml" \
		-p spectre-daemon --features embed-ui
	install -D -m 755 "$WORK/target/spctr/release/spectre-daemon" \
		"$STAGE/usr/local/bin/spectre-daemon"
	install -D -m 644 "$SRC/bastion/tools/spectre/config.toml" "$STAGE/etc/spectre/config.toml"
	install -D -m 644 "$dir/spectre-daemon/rules.toml" "$STAGE/etc/spectre/rules.toml"
	install -D -m 644 "$SRC/bastion/tools/spectre/spectre.service" \
		"$STAGE/etc/systemd/system/spectre.service"
}

rm -rf "$STAGE"
mkdir -p "$WORK/src" "$STAGE"
built=() skipped=()

while read -r -u 3 name kind source bins; do
	case "$name" in ''|'#'*) continue ;; esac
	if ! dir="$(fetch "$name" "$source")"; then
		if [ "$source" = local ]; then
			skipped+=("$name (local only; set BASTION_TOOLS_DIR)")
		else
			skipped+=("$name (could not clone $source; private? set GITHUB_TOKEN)")
		fi
		continue
	fi
	log "Building $name ($kind) from $dir"
	case "$kind" in
	python) build_python "$name" "$dir" ;;
	cargo) build_cargo "$name" "$dir" "$bins" ;;
	spctr) build_spctr "$dir" ;;
	*) warn "unknown kind '$kind' for $name"; skipped+=("$name (unknown kind)"); continue ;;
	esac
	built+=("$name")
done 3< "$LIST"

log "Tools built: ${built[*]:-none}"
for s in "${skipped[@]}"; do warn "skipped $s"; done
