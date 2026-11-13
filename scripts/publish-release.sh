#!/usr/bin/env bash
#
# Publishes the files in dist/ as a GitHub release, so the built images, the ISO
# and the binaries are downloadable from the repository page.
#
# Usage:  scripts/publish-release.sh <tag> [repo-dir]
#   e.g.  scripts/publish-release.sh v1.0
#
# Needs the GitHub CLI, signed in (gh auth login) or a token in GH_TOKEN.
#
# GitHub limits a release asset to 2 GiB. Anything larger is split into 1900 MiB
# parts, which the release notes tell you how to join back together - a
# super.img is routinely bigger than the limit, so this is not optional.
#
set -euo pipefail

TAG="${1:-}"
REPO_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DIST="$REPO_DIR/dist"
LIMIT_MB=1900

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$TAG" ] || die "usage: $0 <tag> [repo-dir]"
[ -d "$DIST" ] || die "nothing in $DIST - run ./build.sh artifacts <arch> first"
command -v gh >/dev/null 2>&1 || die "gh is not installed: https://cli.github.com"

# ------------------------------------------------------------------- notes ---
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT

{
  echo "**SketchOpenSourceProject** - a lightweight Android 16 build on LineageOS"
  echo "(no Google apps) that installs and runs Debian \`.deb\` packages."
  echo
  echo "Built for **arm64** and **amd64**. dpkg runs inside a Debian chroot, and"
  echo "qemu-user makes the other architecture's packages work too."
  echo
  echo "### Downloads"
  echo
  echo "- \`sketch-*-userdebug.zip\` - unzip, then \`fastboot flashall\`"
  echo "- \`sketch-amd64.iso\` - bootable live medium for amd64"
  echo "- \`bin/\` - the \`sketchd\` binary and the Debian userland tarball"
  echo "- \`SHA256SUMS\` - verify with \`sha256sum -c SHA256SUMS\`"
  echo
  echo "### On the device"
  echo
  echo '```'
  echo "adb root"
  echo "deb rootfs init"
  echo "deb install ./something.deb"
  echo '```'
  echo
  echo "### Files"
  echo
  for f in "$DIST"/*/SHA256SUMS "$DIST"/**/manifest.txt; do
    [ -f "$f" ] || continue
    echo "<details><summary>$(dirname "$f" | xargs basename)/manifest.txt</summary>"
    echo
    echo '```'
    cat "$f"
    echo '```'
    echo "</details>"
    echo
  done
  echo "Anything over 2 GiB is split into \`.partNN\` pieces because of GitHub's"
  echo "per-asset limit; join them with \`cat name.part* > name\`."
} > "$NOTES"

# ------------------------------------------------------------------ release --
if gh release view "$TAG" >/dev/null 2>&1; then
  log "release $TAG exists, adding files"
else
  log "creating release $TAG"
  gh release create "$TAG" --title "SketchOpenSourceProject $TAG" --notes-file "$NOTES"
fi

# ------------------------------------------------------------------- upload --
shopt -s globstar nullglob
for f in "$DIST"/**/*; do
  [ -f "$f" ] || continue
  case "$f" in
    *.part[0-9][0-9]) continue ;;   # uploaded with its parent below
  esac

  size_mb=$(( $(stat -c %s "$f") / 1024 / 1024 ))
  if [ "$size_mb" -le "$LIMIT_MB" ]; then
    log "uploading $(basename "$f") (${size_mb} MiB)"
    gh release upload "$TAG" "$f" --clobber
  else
    log "$(basename "$f") is ${size_mb} MiB - splitting"
    rm -f "$f".part*
    split -b "${LIMIT_MB}M" -d -a 2 "$f" "$f.part"
    for part in "$f".part*; do
      log "  uploading $(basename "$part")"
      gh release upload "$TAG" "$part" --clobber
    done
  fi
done

log "done: $(gh release view "$TAG" --json url -q .url)"
