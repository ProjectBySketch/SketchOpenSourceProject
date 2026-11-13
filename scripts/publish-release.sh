#!/usr/bin/env bash
#
# Publishes the built images, the ISO and the binaries as GitHub releases -
# one release per architecture, so the downloads are unambiguous:
#
#   v1.0-arm64   sketch-arm64-userdebug.zip, sketchd-arm64, rootfs-arm64.tar.gz
#   v1.0-amd64   sketch-amd64-userdebug.zip, sketch-amd64.iso, sketchd-amd64, ...
#
# Usage:
#   scripts/publish-release.sh <tag> [repo-dir]     create/update the releases
#   scripts/publish-release.sh <tag> --list         show what would be published
#   scripts/publish-release.sh <tag> --dry-run      check everything, upload nothing
#
# Needs the GitHub CLI, signed in (gh auth login) or a token in GH_TOKEN.
#
# An architecture is only published when it actually has images in dist/: an
# empty release is worse than no release, so a missing build is an error, not a
# silent success.
#
# GitHub limits a release asset to 2 GiB. Anything larger is split into 1900 MiB
# parts, which the release notes explain - a super.img is routinely bigger than
# the limit, so this is not optional.
#
set -euo pipefail

LIMIT_MB=1900
MODES="upload"

log() { printf '\033[1;34m[sketch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sketch]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[sketch]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: publish-release.sh <tag> [repo-dir] [--list|--dry-run]

  <tag>        version to publish, e.g. v1.0
               -> creates the releases v1.0-arm64 and v1.0-amd64
  --list       print what is in dist/ and what each release would contain
  --dry-run    do everything except create releases and upload
EOF
}

TAG=""
REPO_DIR=""
for arg in "$@"; do
  case "$arg" in
    --list) MODES="list" ;;
    --dry-run) MODES="dry-run" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *)
      if [ -z "$TAG" ]; then
        TAG="$arg"
      elif [ -z "$REPO_DIR" ]; then
        REPO_DIR="$arg"
      else
        die "too many arguments"
      fi
      ;;
  esac
done

[ -n "$TAG" ] || { usage; exit 2; }
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DIST="$REPO_DIR/dist"

[ -d "$DIST" ] || die "nothing in $DIST - run ./build.sh artifacts <arch> first"

if [ "$MODES" = "upload" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is not installed: https://cli.github.com"
fi

# ------------------------------------------------------- what is in dist/? ---
# dist/sketch-<arch>-<variant>/ is the layout make-artifacts.sh writes.
ARCH_DIRS=()
arch_count=0
for dir in "$DIST"/sketch-*-*; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"          # sketch-arm64-userdebug
  arch="${base#sketch-}"; arch="${arch%%-*}"
  variant="${base##*-}"
  if [ -z "$(ls -A "$dir"/*.img 2>/dev/null)" ]; then
    warn "skipping $base: no .img files in it"
    continue
  fi
  ARCH_DIRS+=("$dir|$arch|$variant")
  arch_count=$((arch_count + 1))
done

[ "$arch_count" -gt 0 ] || die "no built architectures in $DIST (expected dist/sketch-<arch>-<variant>/ with *.img)"

log "$arch_count architecture(s) to publish:"
for entry in "${ARCH_DIRS[@]}"; do
  IFS='|' read -r dir arch variant <<< "$entry"
  count=$(ls -1 "$dir"/*.img 2>/dev/null | wc -l)
  extra=""
  if [ -f "$dir/sketch-$arch.iso" ]; then
    extra=" + iso"
  fi
  log "  $arch ($variant): $count images$extra"
done

# ------------------------------------------------------------- publishing ---
publish_one() {
  local dir="$1" arch="$2" variant="$3"
  local rel_tag="$TAG-$arch"
  local title="SketchOpenSourceProject $TAG ($arch)"
  local stage notes

  stage="$(mktemp -d)"
  notes="$(mktemp)"

  # Assets are staged with the architecture in every name, so a file downloaded
  # from a release page is never ambiguous once it is sitting in ~/Downloads.
  # (Plain `if` blocks throughout: `[ -f x ] && cp` would exit under set -e.)
  local f
  for f in "$dir"/*.img; do
    if [ -f "$f" ]; then
      cp -f "$f" "$stage/"
    fi
  done
  if [ -f "$dir/sketch-$arch-$variant.zip" ]; then
    cp -f "$dir/sketch-$arch-$variant.zip" "$stage/"
  fi
  if [ -f "$dir/sketch-$arch.iso" ]; then
    cp -f "$dir/sketch-$arch.iso" "$stage/"
  fi
  if [ -f "$dir/bin/sketchd" ]; then
    cp -f "$dir/bin/sketchd" "$stage/sketchd-$arch"
  fi
  if [ -f "$dir/bin/rootfs-$arch.tar.gz" ]; then
    cp -f "$dir/bin/rootfs-$arch.tar.gz" "$stage/"
  fi
  if [ -f "$dir/manifest.txt" ]; then
    cp -f "$dir/manifest.txt" "$stage/manifest-$arch.txt"
  fi
  if [ -f "$dir/SHA256SUMS" ]; then
    cp -f "$dir/SHA256SUMS" "$stage/SHA256SUMS-$arch"
  fi

  # ------------------------------------------------------------- notes -----
  {
    echo "**SketchOpenSourceProject** $TAG for **$arch** ($variant)"
    echo
    echo "A lightweight Android 16 build on LineageOS, with no Google apps, that"
    echo "installs and runs Debian \`.deb\` packages. dpkg runs inside a Debian"
    echo "chroot, and qemu-user makes the other architecture's packages work too."
    echo
    echo "Supported architectures: **arm64**, **amd64** - each has its own release."
    echo
    echo "### Downloads ($arch)"
    echo
    if [ -f "$dir/sketch-$arch-$variant.zip" ]; then
      echo "- \`sketch-$arch-$variant.zip\` - unzip, then \`fastboot flashall\`"
    fi
    if [ -f "$dir/sketch-$arch.iso" ]; then
      echo "- \`sketch-$arch.iso\` - bootable live medium (boot it, or \`qemu-system-x86_64 -cdrom\`)"
    fi
    echo "- \`sketchd-$arch\` - the .deb runtime binary (the \`deb\` CLI is a symlink to it)"
    echo "- \`rootfs-$arch.tar.gz\` - the Debian userland it unpacks on first use"
    echo "- \`*.img\` - the raw images, if you would rather flash them one by one"
    echo "- \`SHA256SUMS-$arch\` - verify with \`sha256sum -c SHA256SUMS-$arch\`"
    echo
    echo "### On the device"
    echo
    echo '```'
    echo "adb root"
    echo "deb rootfs init"
    echo "deb install ./something.deb"
    echo '```'
    echo
    if [ -f "$stage/manifest-$arch.txt" ]; then
      echo "### What went into it"
      echo
      echo '```'
      cat "$stage/manifest-$arch.txt"
      echo '```'
      echo
    fi
    echo "Assets over 2 GiB are split into \`.partNN\` pieces because of GitHub's"
    echo "per-asset limit; join them with \`cat name.part* > name\`."
  } > "$notes"

  if [ "$MODES" = "list" ]; then
    log "would publish $rel_tag ($title):"
    ( cd "$stage" && ls -1sh ./* | sed 's/^/    /' )
    rm -rf "$stage" "$notes"
    return 0
  fi

  if [ "$MODES" = "dry-run" ]; then
    log "[dry-run] $rel_tag would carry $(ls -1 "$stage" | wc -l) asset(s)"
    rm -rf "$stage" "$notes"
    return 0
  fi

  # ----------------------------------------------------------- release ----
  if gh release view "$rel_tag" >/dev/null 2>&1; then
    log "release $rel_tag exists, adding files"
    gh release edit "$rel_tag" --title "$title" --notes-file "$notes"
  else
    log "creating release $rel_tag"
    gh release create "$rel_tag" --title "$title" --notes-file "$notes"
  fi

  # ------------------------------------------------------------ upload ----
  local file size_mb part
  for file in "$stage"/*; do
    [ -f "$file" ] || continue
    case "$file" in
      *.part[0-9][0-9]) continue ;;   # uploaded with its parent below
    esac

    size_mb=$(( $(stat -c %s "$file") / 1024 / 1024 ))
    if [ "$size_mb" -le "$LIMIT_MB" ]; then
      log "  $rel_tag <- $(basename "$file") (${size_mb} MiB)"
      gh release upload "$rel_tag" "$file" --clobber
    else
      log "  $rel_tag <- $(basename "$file") is ${size_mb} MiB, splitting"
      rm -f "$file".part*
      split -b "${LIMIT_MB}M" -d -a 2 "$file" "$file.part"
      for part in "$file".part*; do
        log "    $(basename "$part")"
        gh release upload "$rel_tag" "$part" --clobber
      done
    fi
  done

  log "published: $(gh release view "$rel_tag" --json url -q .url)"
  rm -rf "$stage" "$notes"
}

for entry in "${ARCH_DIRS[@]}"; do
  IFS='|' read -r dir arch variant <<< "$entry"
  publish_one "$dir" "$arch" "$variant"
done

if [ "$MODES" = "upload" ]; then
  log "all releases are up: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases"
fi
