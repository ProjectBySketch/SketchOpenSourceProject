#!/usr/bin/env bash
#
# Builds the pristine Debian userland that SketchOpenSourceProject unpacks into
# /data on first use.
#
#   scripts/make-rootfs.sh arm64 [repo-dir]
#   scripts/make-rootfs.sh amd64 [repo-dir]
#
# Result: vendor/sketch/rootfs/prebuilt/rootfs-<arch>.tar.gz
#
set -euo pipefail

ARCH="${1:-arm64}"
REPO_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUITE="${SKETCH_SUITE:-trixie}"
MIRROR="${SKETCH_MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SKETCH_SECURITY_MIRROR:-http://security.debian.org/debian-security}"
WORK="${SKETCH_WORKDIR:-$REPO_DIR/.rootfs-build}"
OUT="$REPO_DIR/vendor/sketch/rootfs/prebuilt"

case "$ARCH" in
  arm64) DEB_ARCH=arm64; DEB_QEMU=aarch64 ;;
  amd64) DEB_ARCH=amd64; DEB_QEMU=x86_64 ;;
  *) echo "usage: $0 <arm64|amd64> [repo-dir]" >&2; exit 1 ;;
esac

ROOT="$WORK/rootfs-$ARCH"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

command -v debootstrap >/dev/null 2>&1 || { echo "debootstrap missing: sudo apt install debootstrap" >&2; exit 1; }

# debootstrap on an older distribution may not carry a script for the newest
# Debian suite. Fall back to one it does know rather than failing halfway
# through - the userland is minimal either way.
if [ ! -e "/usr/share/debootstrap/scripts/$SUITE" ]; then
  for fallback in bookworm stable; do
    if [ -e "/usr/share/debootstrap/scripts/$fallback" ]; then
      log "debootstrap has no '$SUITE' script here, using '$fallback'"
      SUITE="$fallback"
      break
    fi
  done
fi

HOST_DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$HOST_DEB_ARCH" != "$DEB_ARCH" ]; then
  # binfmt entries are named after qemu's own arch names, not Debian's.
  if [ ! -e "/proc/sys/fs/binfmt_misc/qemu-$DEB_QEMU" ]; then
    echo "cross-building $DEB_ARCH on $HOST_DEB_ARCH needs qemu-user binfmt registered:" >&2
    echo "  sudo apt install qemu-user-static binfmt-support" >&2
    exit 1
  fi
fi

mkdir -p "$OUT" "$WORK"
if [ -d "$ROOT" ]; then
  log "removing old $ROOT"
  $SUDO rm -rf "$ROOT"
fi

log "debootstrap $SUITE/$DEB_ARCH (minbase)"
$SUDO debootstrap --arch="$DEB_ARCH" --variant=minbase --components=main \
  --include=dpkg,apt,bash,coreutils,tar,gzip,xz-utils,zstd,ca-certificates \
  "$SUITE" "$ROOT" "$MIRROR"

# Belt and braces for a cross build: a binfmt_misc entry registered with the F
# flag makes the kernel hold the interpreter open, but one registered without it
# is resolved inside the chroot instead - so put a copy where it would look.
if [ "$HOST_DEB_ARCH" != "$DEB_ARCH" ] && [ -x "/usr/bin/qemu-$DEB_QEMU-static" ]; then
  log "installing /usr/bin/qemu-$DEB_QEMU-static inside the userland"
  $SUDO mkdir -p "$ROOT/usr/bin"
  $SUDO cp -f "/usr/bin/qemu-$DEB_QEMU-static" "$ROOT/usr/bin/"
fi

log "configuring the userland"
$SUDO cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
cat <<EOF | $SUDO tee "$ROOT/etc/apt/sources.list" >/dev/null
deb $MIRROR $SUITE main
deb $MIRROR $SUITE-updates main
deb $SECURITY_MIRROR $SUITE-security main
EOF

# qemu-user-static carries the static emulators for every target, and the
# kernel's binfmt_misc opens the interpreter inside the chroot, so it has to
# live in the userland: this is what lets an arm64 image run amd64 .debs.
$SUDO chroot "$ROOT" /usr/bin/env -i \
  DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/bash -e -c '
apt-get update
apt-get -y --no-install-recommends install \
  dpkg apt bash coreutils tar gzip xz-utils zstd ca-certificates qemu-user-static
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
mkdir -p dev proc sys tmp var/tmp usr/local/bin root
chmod 1777 tmp var/tmp
'

echo "$DEB_ARCH" | $SUDO tee "$ROOT/etc/sketch-arch" >/dev/null

# /dev, /proc and /sys are mounted by sketchd at run time; leave them empty.
for d in dev proc sys; do
  $SUDO find "$ROOT/$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
done

log "packing (gnu format, so Android's tar reader and ours both cope)"
$SUDO tar --format=gnu -C "$ROOT" --numeric-owner -czf "$OUT/rootfs-$ARCH.tar.gz" .
$SUDO chown "$(id -u):$(id -g)" "$OUT/rootfs-$ARCH.tar.gz"

log "$OUT/rootfs-$ARCH.tar.gz ($(du -h "$OUT/rootfs-$ARCH.tar.gz" | cut -f1))"
log "now: ./build.sh build $ARCH   (the tarball is embedded in /system_ext/sketch)"
