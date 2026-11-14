#!/usr/bin/env bash
#
# Compiles sketchd (the `deb` runtime) for one architecture.
#
#   scripts/build-runtime.sh <amd64|arm64> <output-file>
#
# Native when the host is that architecture, cross when it is not: arm64 needs
# g++-aarch64-linux-gnu, amd64-on-arm64 needs g++-x86-64-linux-gnu.
#
# libstdc++ and libgcc are linked statically, so the result runs on any distro of
# that architecture - that is what makes `sketchd-<arch>` in a release useful on
# a machine other than the one it was built on. libc stays dynamic: inside our
# own userland (and the live medium) it is always there, and an Android image
# builds the same sources with Android.bp instead.
#
set -euo pipefail

ARCH="${1:-}"
OUT="${2:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$ARCH" ] && [ -n "$OUT" ] || die "usage: $0 <amd64|arm64> <output-file>"

case "$ARCH" in
  arm64) TARGET_CC=aarch64-linux-gnu-g++ ;;
  amd64) TARGET_CC=x86_64-linux-gnu-g++ ;;
  *) die "unknown arch '$ARCH' (use arm64 or amd64)" ;;
esac

HOST_ARCH="$(uname -m)"
if { [ "$ARCH" = "amd64" ] && [ "$HOST_ARCH" = "x86_64" ]; } ||
   { [ "$ARCH" = "arm64" ] && [ "$HOST_ARCH" = "aarch64" ]; }; then
  CXX="${CXX:-g++}"
  log "compiling sketchd for $ARCH (native, $CXX)"
else
  CXX="${CXX:-$TARGET_CC}"
  log "compiling sketchd for $ARCH (cross, $CXX)"
fi

command -v "$CXX" >/dev/null 2>&1 || die "$CXX not found: sudo apt install g++ g++-aarch64-linux-gnu g++-x86-64-linux-gnu"

mkdir -p "$(dirname "$OUT")"
# The same sources Android.bp builds.
"$CXX" -std=c++20 -O2 -Wall -Wextra \
    -Wno-unused-parameter -Wno-sign-compare \
    -static-libstdc++ -static-libgcc \
    -I"$REPO_DIR/vendor/sketch" \
    -o "$OUT" "$REPO_DIR"/vendor/sketch/sketchd/*.cpp

log "built $OUT ($(du -h "$OUT" | cut -f1), $ARCH)"

# Only a native binary can be asked what it is; the cross one needs an emulator.
if command -v file >/dev/null 2>&1; then
  file "$OUT"
fi
if [ "$CXX" = "g++" ]; then
  "$OUT" about | head -2
fi
