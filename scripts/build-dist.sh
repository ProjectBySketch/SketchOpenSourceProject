#!/usr/bin/env bash
#
# Builds everything this project can produce *without* an Android tree, for one
# architecture, and lays it out exactly the way publish-release.sh expects:
#
#   dist/sketch-<arch>-live/
#       bin/sketchd                 the .deb runtime, compiled for <arch>
#       bin/rootfs-<arch>.tar.gz    the Debian userland it unpacks
#       sketch-<arch>-initrd.gz     the same userland as a bootable initramfs
#       sketch-<arch>-vmlinuz       the kernel to boot it with
#       sketch-<arch>.iso           live medium (amd64)
#       sketch-<arch>-live.img      UEFI disk image (amd64)
#       manifest.txt                what this is
#       SHA256SUMS                  verify with `sha256sum -c`
#
# This is the runtime, not the phone image: an Android image still needs the
# LineageOS tree and a machine with room for it (./build.sh build <arch>). What
# runs here is the feature itself, downloadable and bootable.
#
# Usage: scripts/build-dist.sh <amd64|arm64> [variant]
#
# Environment: SKETCH_SUITE, SKETCH_MIRROR, SKETCH_REQUIRE_MEDIA=1
#
set -euo pipefail

ARCH="${1:-amd64}"
VARIANT="${2:-live}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_DIR/dist/sketch-$ARCH-$VARIANT"
WORK="$REPO_DIR/.build/$ARCH"
ROOTFS_DIR="$REPO_DIR/vendor/sketch/rootfs/prebuilt"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

case "$ARCH" in
  arm64|amd64) ;;
  *) die "usage: $0 <amd64|arm64> [variant]" ;;
esac

# debootstrap, a chroot and an archive with real ownership all need root.
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "this needs root, and sudo is not installed"
  exec sudo -E env \
    "SKETCH_REQUIRE_MEDIA=${SKETCH_REQUIRE_MEDIA:-0}" \
    "SKETCH_SUITE=${SKETCH_SUITE:-trixie}" \
    bash "${BASH_SOURCE[0]}" "$@"
fi

rm -rf "$DIST"
mkdir -p "$DIST/bin" "$WORK"

# ------------------------------------------------------------------ runtime ---
bash "$REPO_DIR/scripts/build-runtime.sh" "$ARCH" "$WORK/sketchd"
install -m 0755 "$WORK/sketchd" "$DIST/bin/sketchd"

# ----------------------------------------------------------------- userland ---
bash "$REPO_DIR/scripts/make-rootfs.sh" "$ARCH" "$REPO_DIR"
ROOTFS_TAR="$ROOTFS_DIR/rootfs-$ARCH.tar.gz"
[ -f "$ROOTFS_TAR" ] || die "make-rootfs.sh produced no $ROOTFS_TAR"
cp -f "$ROOTFS_TAR" "$DIST/bin/"

# -------------------------------------------------------------------- media ---
bash "$REPO_DIR/scripts/make-live.sh" "$ARCH" "$ROOTFS_TAR" "$WORK/sketchd" "$DIST"

# ------------------------------------------------------------------- record ---
GIT_REV="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo uncommitted)"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > "$DIST/manifest.txt" <<EOF
SketchOpenSourceProject $ARCH ($VARIANT runtime)
built   $BUILD_DATE
commit  $GIT_REV
host    $(uname -sr) $(uname -m)

What this is
  The Sketch .deb runtime, built and bootable, without an Android image:
  sketchd plus a Debian userland with real dpkg, apt and maintainer scripts.
  Cross-arch works through qemu-user-static, which the userland carries.
  The Android image (debloated LineageOS 23 with `deb` on PATH) is a separate
  build: ./build.sh build $ARCH needs a LineageOS tree.

Boot it (no install, no disk)
  amd64:  qemu-system-x86_64 -m 1G -cdrom sketch-amd64.iso   (or boot it bare metal, or dd it)
          dd if=sketch-amd64-live.img of=/dev/sdX bs=4M       (UEFI)
  arm64:  qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1500 \\
            -kernel sketch-arm64-vmlinuz -initrd sketch-arm64-initrd.gz -nographic

Then, inside it
  deb about
  deb install /root/sketch-hello_1.0_all.deb && sketch-hello
  deb install ./any.deb

On any Linux machine, without booting anything
  ./sketchd-$ARCH about
  SKETCH_BASE=/tmp/sketch ./sketchd-$ARCH rootfs init ./rootfs-$ARCH.tar.gz
  SKETCH_BASE=/tmp/sketch ./sketchd-$ARCH install ./any.deb
EOF

( cd "$DIST" && find . -type f ! -name SHA256SUMS -print0 |
    sort -z | xargs -0 sha256sum > SHA256SUMS )

if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER" "$REPO_DIR/dist" 2>/dev/null || true
fi

log "artifacts for $ARCH in ${DIST#$REPO_DIR/}:"
( cd "$DIST" && find . -type f -printf '%8s  %p\n' | sort -k2 | sed 's/^/  /' ) || true
