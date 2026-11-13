#!/usr/bin/env bash
#
# Puts the SketchOpenSourceProject .deb runtime on an Android device that is
# already rooted - no image build, no flashing, no ISO.
#
# This is the other way to run it without building anything: the runtime is one
# binary plus a userland tarball, so it can be pushed onto a phone you already
# have. It is how you try the feature before committing to a full ROM build.
#
#   bash scripts/install-onto-device.sh [--serial <device>]
#
# What it does:
#   1. builds sketchd for the device ABI with the NDK, or uses a prebuilt binary
#      you point at with SKETCH_DEVICE_BIN
#   2. pushes sketchd and a userland tarball to /data/local/tmp
#   3. installs them under /data/sketch with the layout sketchd expects
#   4. runs `deb about`, `deb rootfs init` and `deb arch` to prove it works
#
# Requirements: a rooted device (userdebug or magisk), adb, and an NDK at
# $ANDROID_NDK_HOME to cross-compile. If you already have a sketchd built for
# the device ABI, set SKETCH_DEVICE_BIN to it and the NDK is not needed.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v adb >/dev/null 2>&1 || die "adb is not installed"

ADB="adb"
if [ -n "$SERIAL" ]; then
  ADB="adb -s $SERIAL"
fi
$ADB get-state >/dev/null 2>&1 || die "no device: check 'adb devices'"

# --------------------------------------------------------------- the ABI ----
ABI="$($ADB shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in
  arm64-v8a)   DEB_ARrm64;  NDK_TRIPLE=aarch64-linux-android ;;
  armeabi-v7a) DEB_ARrmhf;  NDK_TRIPLE=armv7a-linux-androideabi ;;
  x86_64)      DEB_ARmd64;  NDK_TRIPLE=x86_64-linux-android ;;
  x86)         DEB_ARCH=i386;   NDK_TRIPLE=i686-linux-android ;;
  *) die "unsupported ABI: $ABI" ;;
esac
log "device ABI $ABI -> Debian $DEB_ARCH"

# --------------------------------------------------------------- root -------
$ADB shell "su -c id" 2>/dev/null | grep -q 'uid=0' \
  || die "the device is not rooted: 'su -c id' must print uid=0 (userdebug build or magisk)"

# ------------------------------------------------------------- sketchd ------
BIN="${SKETCH_DEVICE_BIN:-}"
if [ -z "$BIN" ]; then
  NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  [ -n "$NDK" ] || die "set ANDROID_NDK_HOME to cross-compile, or SKETCH_DEVICE_BIN to a prebuilt sketchd"
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
  CXX="$TOOLCHAIN/${NDK_TRIPLE}26-clang++"
  [ -x "$CXX" ] || die "no compiler at $CXX (check ANDROID_NDK_HOME)"

  log "cross-compiling sketchd for $ABI"
  BIN="$WORK/sketchd-$DEB_ARCH"
  "$CXX" -std=c++20 -O2 -static-libstdc++ -Wall -Wextra \
      -Wno-unused-parameter -Wno-sign-compare \
      -I"$REPO_DIR/vendor/sketch" \
      -o "$BIN" "$REPO_DIR"/vendor/sketch/sketchd/*.cpp
fi
[ -f "$BIN" ] || die "no sketchd binary at $BIN"
log "using $BIN ($(du -h "$BIN" | cut -f1))"

# ------------------------------------------------------------- userland -----
TARBALL="${SKETCH_DEVICE_ROOTFS:-$REPO_DIR/vendor/sketch/rootfs/prebuilt/rootfs-$DEB_ARCH.tar.gz}"
if [ ! -f "$TARBALL" ]; then
  die "no userland tarball for $DEB_ARCH.
Build one on a Linux host with:  bash build.sh rootfs $DEB_ARCH
then point at it with:           SKETCH_DEVICE_ROOTFS=/path/rootfs-$DEB_ARCH.tar.gz"
fi
log "userland $TARBALL ($(du -h "$TARBALL" | cut -f1))"

# --------------------------------------------------------------- install ----
log "pushing to /data/local/tmp"
$ADB push "$BIN" /data/local/tmp/sketchd >/dev/null
$ADB push "$TARBALL" "/data/local/tmp/rootfs-$DEB_ARCH.tar.gz" >/dev/null

log "installing under /data/sketch"
$ADB shell "su -c '
  set -e
  mkdir -p /data/sketch/bin
  cp /data/local/tmp/sketchd /data/sketch/bin/sketchd
  chmod 0755 /data/sketch/bin/sketchd
  ln -sf /data/sketch/bin/sketchd /data/sketch/bin/deb
  cp /data/local/tmp/rootfs-$DEB_ARCH.tar.gz /data/sketch/rootfs-$DEB_ARCH.tar.gz
  rm -f /data/local/tmp/sketchd /data/local/tmp/rootfs-$DEB_ARCH.tar.gz
'"

log "running it on the device"
$ADB shell "su -c '/data/sketch/bin/deb about'"
$ADB shell "su -c '/data/sketch/bin/deb rootfs init'"
$ADB shell "su -c '/data/sketch/bin/deb arch'"

cat <<EOF

Installed. On the device:

  su -c '/data/sketch/bin/deb install /sdcard/Download/something.deb'
  su -c '/data/sketch/bin/deb run <command>'
  su -c '/data/sketch/bin/deb shell'

The CLI lives at /data/sketch/bin/deb. On a userdebug build with a writable
system ('adb remount') you can put it on PATH for every root shell:

  adb push /data/sketch/bin/sketchd /system/bin/sketchd && adb shell chmod 0755 /system/bin/sketchd
EOF
