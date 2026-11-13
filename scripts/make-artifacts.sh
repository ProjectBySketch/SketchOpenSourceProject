#!/usr/bin/env bash
#
# Collects everything a build produced into dist/, ready to publish:
#
#   dist/sketch-<arch>-<variant>/
#       *.img                      every image the build made (system, boot, ...)
#       bin/sketchd                the .deb runtime binary
#       bin/rootfs-<arch>.tar.gz   the Debian userland it unpacks
#       sketch-<arch>-<variant>.zip    flashable bundle (fastboot)
#       sketch-<arch>.iso          bootable live medium (amd64 only)
#       manifest.txt               what this is, and what went into it
#       SHA256SUMS                 for verifying a download
#
# Usage:  scripts/make-artifacts.sh <arm64|amd64> [variant] [repo-dir]
#   AOSP_DIR   where the LineageOS tree is   (default $HOME/lineage)
#
set -euo pipefail

ARCH="${1:-arm64}"
VARIANT="${2:-userdebug}"
REPO_DIR="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AOSP_DIR="${AOSP_DIR:-$HOME/lineage}"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

case "$ARCH" in
  arm64|amd64) ;;
  *) die "usage: $0 <arm64|amd64> [variant] [repo-dir]" ;;
esac

DIST="$REPO_DIR/dist/sketch-$ARCH-$VARIANT"

# ---------------------------------------------------------------- find out/ --
# TARGET_DEVICE decides the product directory (generic_arm64, generic_x86_64,
# or whatever a real device tree sets), so the newest system.img is looked up
# rather than guessed.
OUT_DIR=""
if [ -d "$AOSP_DIR/out/target/product" ]; then
  OUT_DIR="$(find "$AOSP_DIR/out/target/product" -maxdepth 2 -name system.img \
    -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$OUT_DIR" ] && [ -d "$OUT_DIR" ] || die "no built images under $AOSP_DIR/out/target/product (run: ./build.sh build $ARCH)"

log "build output: $OUT_DIR"
rm -rf "$DIST"
mkdir -p "$DIST/bin"

# --------------------------------------------------------------- the images --
# Anything the build made that is worth flashing. Missing ones are skipped, so
# this works for both a dynamic-partition device (super.img) and a plain one.
IMAGES="boot.img system.img system_ext.img vendor.img product.img \
        userdata.img vbmeta.img vbmeta_system.img dtbo.img super.img \
        ramdisk.img ramdisk-recovery.img kernel cache.img odm.img"

copied=0
for img in $IMAGES; do
  if [ -f "$OUT_DIR/$img" ]; then
    cp -f "$OUT_DIR/$img" "$DIST/$img"
    copied=$((copied + 1))
  fi
done
[ "$copied" -gt 0 ] || die "nothing to collect in $OUT_DIR"
log "collected $copied images"

# ------------------------------------------------------------- the binaries --
if [ -f "$OUT_DIR/system_ext/bin/sketchd" ]; then
  cp -f "$OUT_DIR/system_ext/bin/sketchd" "$DIST/bin/sketchd"
  log "collected sketchd"
else
  log "warning: $OUT_DIR/system_ext/bin/sketchd is missing (is sketchd in PRODUCT_PACKAGES?)"
fi

for tarball in "$REPO_DIR"/vendor/sketch/rootfs/prebuilt/rootfs-*.tar.gz; do
  [ -f "$tarball" ] || continue
  cp -f "$tarball" "$DIST/bin/"
  log "collected $(basename "$tarball")"
done

# ------------------------------------------------------ the flashable bundle --
# Same shape as a LineageOS *-img-*.zip: unzip and `fastboot flash` each image.
if command -v zip >/dev/null 2>&1; then
  ( cd "$DIST" && zip -q -r "sketch-$ARCH-$VARIANT.zip" ./*.img )
  log "flashable bundle: sketch-$ARCH-$VARIANT.zip"
else
  log "warning: zip missing, no flashable bundle (sudo apt install zip)"
fi

# ------------------------------------------------------------- the live ISO --
# amd64 only, and only when the ISO tools are installed. This is a live medium
# assembled from the images the build made, in the same way Android-x86 does it:
# a GRUB menu boots the kernel with the x86_64 command line and the initrd
# mounts system.img from the ISO.
if [ "$ARCH" = "amd64" ]; then
  if command -v grub-mkrescue >/dev/null 2>&1 && command -v xorriso >/dev/null 2>&1; then
    if [ -f "$DIST/kernel" ] && [ -f "$DIST/ramdisk.img" ] && [ -f "$DIST/system.img" ]; then
      ISO_ROOT="$(mktemp -d)"
      mkdir -p "$ISO_ROOT/boot/grub" "$ISO_ROOT/sketch"
      cp -f "$DIST/kernel" "$ISO_ROOT/boot/kernel"
      cp -f "$DIST/ramdisk.img" "$ISO_ROOT/boot/initrd.img"
      cp -f "$DIST/system.img" "$ISO_ROOT/sketch/system.img"
      if [ -f "$DIST/system_ext.img" ]; then
        cp -f "$DIST/system_ext.img" "$ISO_ROOT/sketch/system_ext.img"
      fi

      cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "SketchOpenSourceProject amd64 (live)" {
    linux /boot/kernel androidboot.hardware=android_x86_64 \
          androidboot.selinux=permissive androidboot.console=ttyS0 \
          console=tty0 SRC=/sketch/system.img
    initrd /boot/initrd.img
}

menuentry "SketchOpenSourceProject amd64 (live, no SELinux)" {
    linux /boot/kernel androidboot.hardware=android_x86_64 \
          androidboot.selinux=disabled console=tty0 SRC=/sketch/system.img
    initrd /boot/initrd.img
}
EOF

      log "building the ISO (grub-mkrescue)"
      if grub-mkrescue -o "$DIST/sketch-$ARCH.iso" "$ISO_ROOT" >/dev/null 2>&1; then
        log "live ISO: sketch-$ARCH.iso"
      else
        log "warning: grub-mkrescue failed; the ISO was not built (images are still here)"
      fi
      rm -rf "$ISO_ROOT"
    else
      log "warning: kernel/ramdisk.img/system.img missing; no ISO"
    fi
  else
    log "warning: grub-mkrescue or xorriso missing; no ISO (sudo apt install grub-pc-bin grub-efi-amd64-bin xorriso)"
  fi
fi

# --------------------------------------------------------------- the record --
GIT_REV="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo uncommitted)"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > "$DIST/manifest.txt" <<EOF
SketchOpenSourceProject $ARCH ($VARIANT)
built   $BUILD_DATE
commit  $GIT_REV
out     $OUT_DIR
host    $(uname -sr) $(uname -m)

What this is
  A lightweight Android 16 build on LineageOS, with no Google apps, and with the
  Sketch .deb runtime: dpkg inside a Debian chroot, cross-arch through qemu-user.

Flash it
  fastboot flashall              from the unzipped bundle (or flash each .img)

Run the live ISO (amd64)
  qemu-system-x86_64 -m 4G -cdrom sketch-amd64.iso   (or boot it on bare metal)

Install a .deb on the device
  adb root && deb rootfs init && deb install ./foo.deb

Images included
EOF
( cd "$DIST" && ls -1 ./*.img 2>/dev/null | sed 's|^\./|  |' >> manifest.txt ) || true

( cd "$DIST" && sha256sum ./* 2>/dev/null > SHA256SUMS ) || true

log "artifacts in $DIST"
ls -1sh "$DIST"
