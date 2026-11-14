#!/usr/bin/env bash
#
# Builds bootable media for the Sketch .deb runtime - no Android image, no
# emulator image, no LineageOS tree:
#
#   amd64   sketch-amd64.iso        live medium: BIOS + UEFI, and dd-able to USB
#           sketch-amd64-live.img   UEFI disk image holding the same payload
#   both    sketch-<arch>-vmlinuz   the kernel it boots
#           sketch-<arch>-initrd.gz the Debian userland as an initramfs
#
# The medium is the Debian userland itself, packed as an initramfs, with sketchd
# inside it: boot it and you are in a Debian shell with `deb` on PATH, so
# `deb install foo.deb` works with nothing installed and no disk touched. That is
# the whole feature, running - the Android image is a separate thing.
#
# Needs root: a chroot to fetch a kernel, and real ownership in the archive.
#
# Usage: scripts/make-live.sh <amd64|arm64> [rootfs-tar] [sketchd-bin] [out-dir]
#
# Environment:
#   SKETCH_REQUIRE_MEDIA=1   fail when the media tools are missing (CI sets this)
#   SKETCH_KERNEL=<vmlinuz>  use this kernel instead of downloading one
#   SKETCH_SUITE             Debian suite (default: trixie)
#
set -euo pipefail

ARCH="${1:-amd64}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS_TAR="${2:-$REPO_DIR/vendor/sketch/rootfs/prebuilt/rootfs-$ARCH.tar.gz}"
RUNTIME_BIN="${3:-}"
OUT_DIR="${4:-$REPO_DIR/dist/sketch-$ARCH-live}"
MIRROR="${SKETCH_MIRROR:-http://deb.debian.org/debian}"
WORK="$REPO_DIR/.media/$ARCH"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sketch]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

case "$ARCH" in
  amd64) DEB_ARCH=amd64; FLAVOUR=linux-image-amd64 ;;
  arm64) DEB_ARCH=arm64; FLAVOUR=linux-image-arm64 ;;
  *) die "usage: $0 <amd64|arm64> [rootfs-tar] [sketchd-bin] [out-dir]" ;;
esac

media_missing() {
  if [ "${SKETCH_REQUIRE_MEDIA:-0}" = "1" ]; then
    die "$1"
  fi
  warn "$1"
}

# A chroot and a packed archive with real ownership both need root.
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "this needs root, and sudo is not installed"
  exec sudo -E env \
    "SKETCH_REQUIRE_MEDIA=${SKETCH_REQUIRE_MEDIA:-0}" \
    "SKETCH_SUITE=${SKETCH_SUITE:-trixie}" "SKETCH_MIRROR=$MIRROR" \
    bash "${BASH_SOURCE[0]}" "$@"
fi

[ -f "$ROOTFS_TAR" ] || die "no userland tarball at $ROOTFS_TAR (run: ./build.sh rootfs $ARCH)"
command -v cpio >/dev/null 2>&1 || die "cpio is missing: sudo apt install cpio"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"
LIVE="$WORK/live"

# --------------------------------------------------------------- the userland -
log "unpacking $ROOTFS_TAR"
mkdir -p "$LIVE"
tar -xzf "$ROOTFS_TAR" -C "$LIVE"

if [ -n "$RUNTIME_BIN" ] && [ -f "$RUNTIME_BIN" ]; then
  log "adding $RUNTIME_BIN to the userland as /usr/bin/sketchd"
  install -m 0755 "$RUNTIME_BIN" "$LIVE/usr/bin/sketchd"
  ln -sf sketchd "$LIVE/usr/bin/deb"
else
  warn "no sketchd binary given: the medium will boot without \`deb\`"
fi

echo "$DEB_ARCH" > "$LIVE/etc/sketch-arch"
mkdir -p "$LIVE/root" "$LIVE/boot"

# ------------------------------------------------------------------- init -----
# PID 1 on the medium. Deliberately not systemd: all this has to do is mount the
# pseudo-filesystems, mount a writable /run and /tmp, and hand out shells.
cat > "$LIVE/init" <<'INIT'
#!/bin/bash
# SketchOpenSourceProject live medium - PID 1.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TERM=linux LANG=C.UTF-8
# The userland *is* the system here, so sketchd must not try to chroot into a
# copy of it: SKETCH_ROOTFS=/ makes `deb` work on this very filesystem.
export SKETCH_ROOTFS=/ SKETCH_BASE=/var/lib/sketch

mount -t proc     proc     /proc 2>/dev/null || true
mount -t sysfs    sysfs    /sys  2>/dev/null || true
mount -t devtmpfs devtmpfs /dev  2>/dev/null || true

mkdir -p /dev/pts /run /run/lock /tmp /var/tmp
chmod 1777 /tmp /var/tmp
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs  tmpfs  /run     2>/dev/null || true

banner() {
  cat <<'MSG'

  ====================================================================
   SketchOpenSourceProject - live medium
   a Debian userland that installs and runs .deb packages
  ====================================================================

  You are root, in a Debian userland, with the Sketch runtime on PATH:

      deb about                     what this is
      deb install ./foo.deb         install a Debian package
      deb list                      what is installed
      deb shell                     this shell, in the same userland

  A demonstration package ships with the medium:

      deb install /root/sketch-hello_1.0_all.deb && sketch-hello

  Nothing is written to any disk: the whole system lives in memory, so
  `poweroff -f` throws it away. apt and dpkg work normally meanwhile.

MSG
}

# Console devices differ by architecture: ttyS0 on a PC, ttyAMA0 on arm64 (the
# PL011), hvc0 under some hypervisors. Try them all; a shell appears on whichever
# exist.
consoles() { echo "tty1 tty2 ttyS0 ttyAMA0 hvc0"; }

for c in $(consoles); do
  if [ -c "/dev/$c" ]; then
    banner > "/dev/$c" 2>/dev/null || true
  fi
done

# One respawning shell per console, so a closed session is not a dead machine.
spawn() {
  local tty="$1"
  while :; do
    if [ -c "/dev/$tty" ]; then
      setsid /bin/bash -i <"/dev/$tty" >"/dev/$tty" 2>&1
    fi
    sleep 2
  done
}

for tty in $(consoles); do
  spawn "$tty" &
done
wait
INIT
chmod 0755 "$LIVE/init"

# ----------------------------------------------------- the demonstration .deb -
# Architecture: all, so one package serves both media, and it is the same test
# CI runs against a downloaded medium: install it, then run it.
if command -v dpkg-deb >/dev/null 2>&1; then
  DEMO="$WORK/demo"
  mkdir -p "$DEMO/DEBIAN" "$DEMO/usr/bin"
  cat > "$DEMO/usr/bin/sketch-hello" <<'HELLO'
#!/bin/sh
echo "hello from a Debian package, running on the Sketch live medium"
echo "kernel: $(uname -srm)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "this is $PRETTY_NAME"; fi
HELLO
  chmod 0755 "$DEMO/usr/bin/sketch-hello"
  cat > "$DEMO/DEBIAN/control" <<'CONTROL'
Package: sketch-hello
Version: 1.0
Architecture: all
Maintainer: SketchOpenSourceProject <noreply@example.invalid>
Section: misc
Priority: optional
Description: demonstration package for the Sketch .deb runtime
 Prints a few lines from inside the Debian userland.
CONTROL
  dpkg-deb --build --root-owner-group "$DEMO" \
    "$LIVE/root/sketch-hello_1.0_all.deb" >/dev/null
  log "demo package: /root/sketch-hello_1.0_all.deb"
else
  warn "dpkg-deb missing (sudo apt install dpkg-dev): no demo package on the medium"
fi

# ------------------------------------------------------------------ kernel ----
# Taken straight out of Debian's kernel .deb and unpacked by hand: a package
# postinst would want /proc and a boot loader, and none of that is needed to get
# a vmlinuz.
KERNEL="$OUT_DIR/sketch-$ARCH-vmlinuz"

if [ -n "${SKETCH_KERNEL:-}" ]; then
  [ -f "$SKETCH_KERNEL" ] || die "SKETCH_KERNEL=$SKETCH_KERNEL does not exist"
  log "using kernel $SKETCH_KERNEL"
  cp -f "$SKETCH_KERNEL" "$KERNEL"
else
  log "fetching $FLAVOUR for $DEB_ARCH"
  KROOT="$WORK/kernelroot"
  mkdir -p "$KROOT"
  cp -a "$LIVE/." "$KROOT"/
  cp -f /etc/resolv.conf "$KROOT/etc/resolv.conf" 2>/dev/null || true

  PKG="$(chroot "$KROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
          apt-cache depends "$FLAVOUR" 2>/dev/null |
          awk '/linux-image-[0-9]/{print $2; exit}')"
  [ -n "$PKG" ] || die "could not resolve $FLAVOUR for $DEB_ARCH (does $MIRROR carry it?)"
  log "  -> $PKG"

  if ! chroot "$KROOT" /usr/bin/env -i DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -c \
        "apt-get update -qq && apt-get download $PKG" >"$WORK/apt.log" 2>&1; then
    tail -20 "$WORK/apt.log" >&2
    die "could not download $PKG"
  fi

  EXTRACT="$WORK/kernel-extract"
  mkdir -p "$EXTRACT"
  found=""
  for deb in "$KROOT"/*.deb; do
    if [ -f "$deb" ]; then
      dpkg-deb -x "$deb" "$EXTRACT"
      found="$deb"
    fi
  done
  [ -n "$found" ] || die "apt-get download produced no .deb"

  VMLINUZ="$(find "$EXTRACT" -name 'vmlinuz-*' -type f | head -1)"
  [ -n "$VMLINUZ" ] || die "no vmlinuz inside $(basename "$found")"
  cp -f "$VMLINUZ" "$KERNEL"
  rm -rf "$KROOT" "$EXTRACT"
fi

log "kernel: $(basename "$KERNEL") ($(du -h "$KERNEL" | cut -f1))"

# --------------------------------------------------------------- the initrd ---
# The whole userland as a cpio archive: the machine needs memory, and nothing
# else - no partition, no filesystem driver, no second stage.
log "packing the initramfs (the bulk of the medium)"
( cd "$LIVE" && find . -print0 | cpio --null -o --format=newc --quiet ) |
  gzip -9 > "$OUT_DIR/sketch-$ARCH-initrd.gz"
log "initramfs: $(du -h "$OUT_DIR/sketch-$ARCH-initrd.gz" | cut -f1)"

# ------------------------------------------------------------------- media ----
write_grub_cfg() {
  cat > "$1" <<EOF
set timeout=10
set timeout_style=menu

menuentry "SketchOpenSourceProject live - .deb support (VGA console)" {
    linux $2 console=tty0 console=ttyS0,115200 panic=30 loglevel=4
    initrd $3
}

menuentry "SketchOpenSourceProject live - .deb support (serial console)" {
    linux $2 console=ttyS0,115200 console=tty0 panic=30 loglevel=4
    initrd $3
}
EOF
}

build_iso() {
  local iso="$OUT_DIR/sketch-$ARCH.iso" isodir="$WORK/iso"
  if ! command -v grub-mkrescue >/dev/null 2>&1 || ! command -v xorriso >/dev/null 2>&1; then
    media_missing "no ISO: grub-mkrescue/xorriso missing (sudo apt install grub-pc-bin grub-efi-amd64-bin xorriso mtools)"
    return 0
  fi
  rm -rf "$isodir"
  mkdir -p "$isodir/boot/grub"
  cp -f "$KERNEL" "$isodir/boot/vmlinuz"
  cp -f "$OUT_DIR/sketch-$ARCH-initrd.gz" "$isodir/boot/initrd.img"
  write_grub_cfg "$isodir/boot/grub/grub.cfg" /boot/vmlinuz /boot/initrd.img

  log "building the ISO (grub-mkrescue: BIOS + UEFI, dd-able)"
  if grub-mkrescue -o "$iso" "$isodir" >"$WORK/grub.log" 2>&1; then
    log "ISO: $(du -h "$iso" | cut -f1) $(basename "$iso")"
  else
    tail -20 "$WORK/grub.log" >&2
    media_missing "grub-mkrescue failed (see the log above)"
  fi
}

build_disk_image() {
  local img="$OUT_DIR/sketch-$ARCH-live.img" efi="$WORK/BOOTX64.EFI" cfg="$WORK/efi-grub.cfg" tool
  for tool in grub-mkstandalone mkfs.vfat mmd mcopy; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      media_missing "no .img: $tool missing (sudo apt install grub-efi-amd64-bin dosfstools mtools)"
      return 0
    fi
  done

  # The built-in config looks the payload up by filesystem label, so the image
  # works wherever the firmware puts it (dd'd to a stick, or as a disk file).
  cat > "$cfg" <<'EOF'
set timeout=10
search --label --no-floppy --set=root SKETCH
menuentry "SketchOpenSourceProject live - .deb support" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 panic=30 loglevel=4
    initrd /boot/initrd.img
}
EOF

  if ! grub-mkstandalone -O x86_64-efi -o "$efi" \
        --modules="part_gpt part_msdos fat iso9660 search search_label search_fs_label normal linux configfile all_video echo test" \
        "boot/grub/grub.cfg=$cfg" >"$WORK/grub-standalone.log" 2>&1; then
    tail -20 "$WORK/grub-standalone.log" >&2
    media_missing "grub-mkstandalone failed, no .img"
    return 0
  fi

  local need
  need=$(( ( $(stat -c %s "$efi") + $(stat -c %s "$KERNEL") +
             $(stat -c %s "$OUT_DIR/sketch-$ARCH-initrd.gz") ) / 1048576 + 64 ))

  rm -f "$img"
  truncate -s "${need}M" "$img"
  mkfs.vfat -F32 -n SKETCH "$img" >/dev/null
  mmd -i "$img" ::/EFI ::/EFI/BOOT ::/boot
  mcopy -i "$img" "$efi" ::/EFI/BOOT/BOOTX64.EFI
  mcopy -i "$img" "$KERNEL" ::/boot/vmlinuz
  mcopy -i "$img" "$OUT_DIR/sketch-$ARCH-initrd.gz" ::/boot/initrd.img
  log "disk image: $(du -h "$img" | cut -f1) $(basename "$img") (UEFI, dd it to a stick)"
}

if [ "$ARCH" = "amd64" ]; then
  build_iso
  build_disk_image
else
  log "arm64: no ISO - GRUB has no arm64 route here. Boot the pair:"
  log "  qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1500 \\"
  log "    -kernel sketch-$ARCH-vmlinuz -initrd sketch-$ARCH-initrd.gz -nographic"
fi

# Root made these; make them the caller's again.
if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER" "$OUT_DIR" 2>/dev/null || true
fi

rm -rf "$WORK"
log "media for $ARCH:"
( cd "$OUT_DIR" && ls -1sh ./* 2>/dev/null | sed 's/^/  /' ) || true
