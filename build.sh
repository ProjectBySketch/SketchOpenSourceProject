#!/usr/bin/env bash
#
# SketchOpenSourceProject - a lightweight Android 16 build on LineageOS (no
# Google apps) that installs and runs Debian .deb packages, for arm64 and amd64.
#
#   ./build.sh env                 check the host can build LineageOS
#   ./build.sh sync                repo init/sync LineageOS + link vendor/sketch
#   ./build.sh rootfs [arch]       build the Debian userland tarball(s)
#   ./build.sh build <arch> [var]  lunch + build (arch: arm64|amd64, var: userdebug|user)
#   ./build.sh both                build both architectures, userdebug
#   ./build.sh artifacts <arch>    collect images, ISO and binaries into dist/
#   ./build.sh publish <tag>       upload dist/ as a GitHub release
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOSP_DIR="${AOSP_DIR:-$HOME/lineage}"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-23.0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

lunch_target() {
  case "$1" in
    arm64|aarch64) echo "sketch_arm64-$2" ;;
    amd64|x86_64|x64) echo "sketch_x86_64-$2" ;;
    *) die "unknown arch '$1' (use arm64 or amd64)" ;;
  esac
}

cmd_env() {
  bash "$REPO_DIR/scripts/check-env.sh"
}

cmd_sync() {
  bash "$REPO_DIR/scripts/fetch-lineage.sh" "$AOSP_DIR" "$LINEAGE_BRANCH"
  bash "$REPO_DIR/scripts/link-vendor.sh" "$REPO_DIR" "$AOSP_DIR"
}

cmd_rootfs() {
  local arch="${1:-both}"
  case "$arch" in
    both)
      bash "$REPO_DIR/scripts/make-rootfs.sh" arm64 "$REPO_DIR"
      bash "$REPO_DIR/scripts/make-rootfs.sh" amd64 "$REPO_DIR"
      ;;
    arm64|amd64)
      bash "$REPO_DIR/scripts/make-rootfs.sh" "$arch" "$REPO_DIR"
      ;;
    *) die "unknown arch '$arch' (use arm64, amd64 or both)" ;;
  esac
}

cmd_build() {
  local arch="${1:-arm64}" variant="${2:-userdebug}"
  [ -d "$AOSP_DIR/build/make" ] || die "no LineageOS tree at $AOSP_DIR (run: $0 sync)"
  local target
  target="$(lunch_target "$arch" "$variant")"
  log "building $target"
  (
    cd "$AOSP_DIR"
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch "$target"
    # The default target builds bacon, which produces every image that matters
    # here (system, system_ext) plus sketchd and deb from PRODUCT_PACKAGES.
    m -j"$JOBS"
  )
  log "images in $AOSP_DIR/out/target/product/*/"
}

cmd_both() {
  cmd_build arm64 userdebug
  cmd_build amd64 userdebug
}

cmd_artifacts() {
  local arch="${1:-arm64}" variant="${2:-userdebug}"
  bash "$REPO_DIR/scripts/make-artifacts.sh" "$arch" "$variant" "$REPO_DIR"
}

cmd_publish() {
  local tag="${1:-}"
  [ -n "$tag" ] || die "usage: $0 publish <tag> [--list|--dry-run]   (e.g. $0 publish v1.0)"
  shift || true
  bash "$REPO_DIR/scripts/publish-release.sh" "$tag" "$REPO_DIR" "$@"
}

usage() {
  cat <<'EOF'
SketchOpenSourceProject build driver

  ./build.sh env                  check the host (tools, RAM, disk)
  ./build.sh sync                 repo init/sync LineageOS, link vendor/sketch
  ./build.sh rootfs [arch]        build Debian userland tarball(s): arm64|amd64|both
  ./build.sh build <arch> [var]   lunch + build (var: userdebug|user)
  ./build.sh both                 build arm64 and amd64 userdebug
  ./build.sh artifacts <arch>     collect images, live ISO and binaries into dist/
  ./build.sh publish <tag>        publish one release per arch: <tag>-arm64, <tag>-amd64
                                  add --list to see what would go up, --dry-run to check

Environment:
  AOSP_DIR        where the LineageOS tree lives  (default: $HOME/lineage)
  LINEAGE_BRANCH  LineageOS branch to sync        (default: lineage-23.0)
  JOBS            parallel make jobs              (default: nproc)

LineageOS is the base on purpose: it is AOSP plus the device support a phone
needs, and it ships with no Google apps, so there is nothing to strip and the
sync is a fraction of AOSP's. 16 GiB of RAM builds one device; 8 GiB works with
JOBS=4.

The usual run, end to end:

  ./build.sh env && ./build.sh sync
  ./build.sh rootfs both
  ./build.sh build arm64 && ./build.sh artifacts arm64
  ./build.sh build amd64 && ./build.sh artifacts amd64
  ./build.sh publish v1.0

`publish` needs the GitHub CLI (gh auth login). Images are gigabytes, so they
go on the Releases page, not in git.
EOF
}

main() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    env) cmd_env ;;
    sync) cmd_sync ;;
    rootfs) cmd_rootfs "${1:-both}" ;;
    build) cmd_build "${1:-arm64}" "${2:-userdebug}" ;;
    both) cmd_both ;;
    artifacts) cmd_artifacts "${1:-arm64}" "${2:-userdebug}" ;;
    publish) cmd_publish "${1:-}" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
