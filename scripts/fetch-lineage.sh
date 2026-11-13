#!/usr/bin/env bash
#
# Fetches the LineageOS tree SketchOpenSourceProject builds on.
#
# LineageOS is AOSP plus the things a phone actually needs (HALs for real
# devices, updater, kernel trees, the Lineage apps), and - unlike a stock AOSP
# checkout - it already ships without any Google apps. That is the whole reason
# this project is built on it: no GApps to strip, far less to download, and a
# phone that is usable out of the box.
#
# The sync is a fraction of AOSP's: LineageOS 23 (Android 16) is roughly 80-120
# GiB instead of 250+, and it builds in 16 GiB of RAM.
#
set -euo pipefail

AOSP_DIR="${1:-$HOME/lineage}"
BRANCH="${2:-${LINEAGE_BRANCH:-lineage-23.0}}"
MANIFEST="https://github.com/LineageOS/android.git"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }

command -v repo >/dev/null 2>&1 || {
  echo "repo is not installed: https://source.android.com/setup/develop#installing-repo" >&2
  exit 1
}

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [ ! -d .repo ]; then
  log "repo init LineageOS $BRANCH in $AOSP_DIR"
  repo init -u "$MANIFEST" -b "$BRANCH" --git-lfs --no-clone-bundle
else
  log "existing checkout in $AOSP_DIR - syncing $BRANCH"
fi

# -c: current branch only. --no-tags: no need for release tags. The result is
# the tree as LineageOS ships it, which contains no Google apps at all.
log "repo sync (much smaller than AOSP: expect 80-120 GiB)"
repo sync -c -j"$(nproc)" --force-sync --no-tags --no-clone-bundle

log "LineageOS tree ready at $AOSP_DIR"
log "device trees are added per phone, e.g. in .repo/local_manifests/"
