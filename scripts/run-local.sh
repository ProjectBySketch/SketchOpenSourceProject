#!/usr/bin/env bash
#
# Runs the SketchOpenSourceProject .deb runtime on this Linux machine, with no
# Android image, no ISO and no emulator.
#
# This works because the .deb feature is not an image: it is one binary
# (sketchd) plus a Debian userland tarball. The same code the phone runs runs
# here, against a real Debian userland, with real dpkg and real packages.
#
#   bash scripts/run-local.sh build      compile sketchd into .local-run/bin
#   bash scripts/run-local.sh userland   build a Debian userland tarball
#   bash scripts/run-local.sh init       unpack it through `sketchd rootfs init`
#   bash scripts/run-local.sh demo       end to end: build a real .deb, install
#                                        it, run it, list it, remove it
#   bash scripts/run-local.sh deb ...    any CLI verb, e.g. `deb list`
#   bash scripts/run-local.sh shell      a shell inside the Debian userland
#
# Everything lives under .local-run/ (gitignored), so nothing on the host is
# touched. The unpack and install steps need root (chroot and bind mounts), so
# they re-exec themselves through sudo.
#
# Environment:
#   SKETCH_LOCAL_DIR   where to put it all   (default: <repo>/.local-run)
#   SKETCH_SUITE       Debian suite          (default: trixie)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${SKETCH_LOCAL_DIR:-$REPO_DIR/.local-run}"
BASE="$WORK/base"
BIN="$WORK/bin/sketchd"
SUITE="${SKETCH_SUITE:-trixie}"
MIRROR="${SKETCH_MIRROR:-http://deb.debian.org/debian}"

export SKETCH_BASE="$BASE"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

host_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) die "unsupported host arch $(uname -m)" ;;
  esac
}

# Re-runs this script as root when the step needs it. Build and inspection do
# not; unpacking and installing do, because they chroot and bind mount.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "this step needs root, and sudo is not installed"
  exec sudo -E env \
    "SKETCH_LOCAL_DIR=$WORK" "SKETCH_BASE=$BASE" \
    "SKETCH_SUITE=$SUITE" "SKETCH_MIRROR=$MIRROR" \
    bash "${BASH_SOURCE[0]}" "$@"
}

need_bin() {
  [ -x "$BIN" ] || die "no sketchd yet - run: bash scripts/run-local.sh build"
}

# ---------------------------------------------------------------- build -----
cmd_build() {
  command -v g++ >/dev/null 2>&1 || die "g++ is missing: sudo apt install g++"
  mkdir -p "$WORK/bin"
  log "compiling sketchd from vendor/sketch/sketchd"
  # The same sources Android.bp builds. glibc is close enough to bionic for this
  # code: pipe2, accept4, clearenv and the socket headers exist on both.
  g++ -std=c++20 -O2 -Wall -Wextra \
      -Wno-unused-parameter -Wno-sign-compare \
      -I"$REPO_DIR/vendor/sketch" \
      -o "$BIN" "$REPO_DIR"/vendor/sketch/sketchd/*.cpp
  log "built $BIN"
  "$BIN" about
}

# ------------------------------------------------------------- userland -----
# Builds the Debian userland with debootstrap and packs it the way
# `./build.sh rootfs` does for the image, so the unpack path is the real one.
cmd_userland() {
  local arch tarball stage d
  arch="$(host_arch)"
  tarball="$BASE/rootfs-$arch.tar.gz"
  stage="$WORK/stage"

  command -v debootstrap >/dev/null 2>&1 \
    || die "debootstrap missing: sudo apt install debootstrap"

  as_root userland

  mkdir -p "$BASE"
  rm -rf "$stage"

  log "debootstrap $SUITE/$arch (minbase) - a couple of minutes the first time"
  debootstrap --arch="$arch" --variant=minbase --components=main \
    --include=dpkg,apt,bash,coreutils,tar,gzip,xz-utils,zstd,ca-certificates \
    "$SUITE" "$stage" "$MIRROR"

  # Mark it so sketchd can tell a complete userland from a half-unpacked one.
  echo "$arch" > "$stage/etc/sketch-arch"

  # /dev, /proc and /sys are mounted at run time; leave them empty.
  for d in dev proc sys; do
    find "$stage/$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  done

  log "packing $tarball"
  tar --format=gnu -C "$stage" --numeric-owner -czf "$tarball" .
  rm -rf "$stage"
  log "$(du -h "$tarball" | cut -f1) -> $tarball"
}

# ----------------------------------------------------------------- init -----
cmd_init() {
  need_bin
  as_root init
  log "unpacking through sketchd's own rootfs init"
  "$BIN" rootfs init
  "$BIN" rootfs status
}

# ----------------------------------------------------------------- demo -----
# The proof: a real .deb, built with dpkg-deb, installed by sketchd into the
# Debian userland, executed inside the chroot, listed, then removed again.
cmd_demo() {
  local arch pkg deb

  need_bin
  command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb missing: sudo apt install dpkg-dev"
  as_root demo

  arch="$(host_arch)"

  # --- make a package ------------------------------------------------------
  pkg="$WORK/pkg"
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin"

  cat > "$pkg/usr/bin/sketch-hello" <<'EOF'
#!/bin/sh
echo "hello from a Debian package, running inside the userland"
echo "kernel: $(uname -srm)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "this is $PRETTY_NAME"; fi
EOF
  chmod 0755 "$pkg/usr/bin/sketch-hello"

  cat > "$pkg/DEBIAN/control" <<EOF
Package: sketch-hello
Version: 1.0
Architecture: $arch
Maintainer: SketchOpenSourceProject <noreply@example.invalid>
Section: misc
Priority: optional
Description: demonstration package for the Sketch .deb runtime
 Prints a few lines from inside the Debian userland.
EOF

  deb="$WORK/sketch-hello_1.0_$arch.deb"
  dpkg-deb --build --root-owner-group "$pkg" "$deb" >/dev/null
  log "built $deb"

  # --- install, run, list, remove -----------------------------------------
  log "installing it with sketchd"
  "$BIN" install "$deb"

  log "running the installed binary inside the chroot"
  "$BIN" run /usr/bin/sketch-hello

  log "asking dpkg what is installed"
  "$BIN" list

  log "removing it again"
  "$BIN" remove sketch-hello

  log "verifying it is gone"
  if "$BIN" run /usr/bin/sketch-hello 2>/dev/null; then
    die "the binary is still there after remove - that is a bug"
  fi
  log "gone, as it should be"
  log ""
  log "end to end: built a .deb, installed it, ran it, listed it, removed it."
}

# ------------------------------------------------------------------ cli -----
cmd_deb() {
  need_bin
  as_root deb "$@"
}

cmd_shell() {
  need_bin
  as_root deb shell
}

usage() {
  cat <<'EOF'
Runs the SketchOpenSourceProject .deb runtime on this Linux machine - no
Android image, no ISO, no emulator.

  bash scripts/run-local.sh build      compile sketchd
  bash scripts/run-local.sh userland   build a Debian userland tarball
  bash scripts/run-local.sh init       unpack it via `sketchd rootfs init`
  bash scripts/run-local.sh demo       end to end with a real .deb
  bash scripts/run-local.sh deb ...    any CLI verb (list, arch, install, ...)
  bash scripts/run-local.sh shell      a shell inside the userland

Or just:

  bash scripts/run-local.sh build
  bash scripts/run-local.sh demo

Everything lands in .local-run/; the unpack and install steps re-exec through
sudo because a chroot and bind mounts need root.
EOF
}

main() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    build) cmd_build ;;
    userland) cmd_userland ;;
    init) cmd_init ;;
    demo) cmd_demo ;;
    deb) cmd_deb "$@" ;;
    shell) cmd_shell ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
