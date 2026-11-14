#!/usr/bin/env bash
#
# Publishes what dist/ holds as GitHub releases - one release per architecture,
# so a download is never ambiguous:
#
#   <tag>-arm64   sketchd-arm64, rootfs-arm64.tar.gz, sketch-arm64-initrd.gz,
#                 sketch-arm64-vmlinuz, ...
#   <tag>-amd64   ... plus sketch-amd64.iso and sketch-amd64-live.img
#
# Usage:
#   scripts/publish-release.sh <tag> [repo-dir]     create/update the releases
#   scripts/publish-release.sh <tag> --list         show what would be published
#   scripts/publish-release.sh <tag> --dry-run      check everything, upload nothing
#
# Needs the GitHub CLI, signed in (gh auth login) or a token in GH_TOKEN.
#
# dist/ may hold more than one directory per architecture (an image build and a
# runtime build, say); everything for one arch goes into that arch's release. A
# directory with nothing publishable in it is skipped, and a run with nothing at
# all is an error: an empty release is worse than no release.
#
# GitHub limits a release asset to 2 GiB. Anything larger is split into 1900 MiB
# parts, which the release notes explain - a super.img is routinely bigger than
# the limit, so this is not optional.
#
set -euo pipefail

LIMIT_MB=1900
MODE="upload"

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
    --list) MODE="list" ;;
    --dry-run) MODE="dry-run" ;;
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

[ -d "$DIST" ] || die "nothing in $DIST - run scripts/build-dist.sh <arch> first"

if [ "$MODE" = "upload" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is not installed: https://cli.github.com"
fi

# --------------------------------------------------------- what is on offer? --
# Prints "<source><TAB><name in the release>" for everything publishable in one
# dist directory. Every asset carries the architecture in its name, so a file in
# ~/Downloads is never ambiguous.
collect_assets() {
  local dir="$1" arch="$2" variant="$3" f
  for f in "$dir"/*.img "$dir"/*.iso "$dir/sketch-$arch-vmlinuz" "$dir/sketch-$arch-initrd.gz"; do
    if [ -f "$f" ]; then printf '%s\t%s\n' "$f" "$(basename "$f")"; fi
  done
  for f in "$dir/sketch-$arch-$variant.zip"; do
    if [ -f "$f" ]; then printf '%s\t%s\n' "$f" "$(basename "$f")"; fi
  done
  if [ -f "$dir/bin/sketchd" ]; then
    printf '%s\t%s\n' "$dir/bin/sketchd" "sketchd-$arch"
  fi
  if [ -f "$dir/bin/rootfs-$arch.tar.gz" ]; then
    printf '%s\t%s\n' "$dir/bin/rootfs-$arch.tar.gz" "rootfs-$arch.tar.gz"
  fi
  if [ -f "$dir/manifest.txt" ]; then
    printf '%s\t%s\n' "$dir/manifest.txt" "manifest-$arch.txt"
  fi
  if [ -f "$dir/SHA256SUMS" ]; then
    printf '%s\t%s\n' "$dir/SHA256SUMS" "SHA256SUMS-$arch"
  fi
}

ARCH_LIST=()
declare -A ARCH_DIRS=()    # arch -> " dir|variant dir|variant"
declare -A ARCH_ASSETS=()  # arch -> how many assets
declare -A ARCH_VARIANT=() # arch -> the variant to describe it as

# Glob order is alphabetical, so an image build (sketch-<arch>-userdebug) is
# layered over a runtime one (sketch-<arch>-live) when both are present.
for dir in "$DIST"/sketch-*-*; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"                  # sketch-arm64-userdebug
  arch="${base#sketch-}"; arch="${arch%%-*}"
  variant="${base##*-}"

  count="$(collect_assets "$dir" "$arch" "$variant" | wc -l)"
  if [ "$count" -eq 0 ]; then
    warn "skipping $base: nothing to publish"
    continue
  fi

  if [ -z "${ARCH_ASSETS[$arch]:-}" ]; then
    ARCH_LIST+=("$arch")
    ARCH_VARIANT[$arch]="$variant"
  fi
  ARCH_ASSETS[$arch]=$(( ${ARCH_ASSETS[$arch]:-0} + count ))
  ARCH_DIRS[$arch]="${ARCH_DIRS[$arch]:-} $dir|$variant"
done

[ "${#ARCH_LIST[@]}" -gt 0 ] ||
  die "no built architectures in $DIST (expected dist/sketch-<arch>-<variant>/ with assets in it)"

log "${#ARCH_LIST[@]} architecture(s) to publish:"
for arch in "${ARCH_LIST[@]}"; do
  extras=""
  for entry in ${ARCH_DIRS[$arch]}; do
    IFS='|' read -r dir variant <<< "$entry"
    if [ -f "$dir/sketch-$arch.iso" ]; then extras="$extras + iso"; fi
    if [ -f "$dir/sketch-$arch-live.img" ]; then extras="$extras + img"; fi
    if [ -f "$dir/sketch-$arch-initrd.gz" ]; then extras="$extras + initrd"; fi
  done
  log "  $arch (${ARCH_VARIANT[$arch]}): ${ARCH_ASSETS[$arch]} assets$extras"
done

describe_asset() {
  case "$1" in
    sketch-*.iso) echo "bootable live medium - boot it, or \`qemu-system-x86_64 -cdrom\`" ;;
    sketch-*-live.img) echo "UEFI disk image - \`dd\` it to a stick, or attach it to a VM" ;;
    sketch-*-initrd.gz) echo "the Debian userland as a bootable initramfs" ;;
    sketch-*-vmlinuz) echo "the kernel to boot the initramfs with" ;;
    sketchd-*) echo "the .deb runtime binary (the \`deb\` CLI is a symlink to it)" ;;
    rootfs-*.tar.gz) echo "the Debian userland it unpacks on first use" ;;
    *.zip) echo "flashable bundle - unzip, then \`fastboot flashall\`" ;;
    *.img) echo "raw image - flash it with fastboot" ;;
    manifest-*) echo "what went into this build" ;;
    SHA256SUMS-*) echo "verify with \`sha256sum -c\`" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------- publishing ---
publish_one() {
  local arch="$1"
  local rel_tag="$TAG-$arch"
  local title="SketchOpenSourceProject $TAG ($arch)"
  local stage notes entry dir variant src dest size_mb part

  stage="$(mktemp -d)"
  notes="$(mktemp)"

  for entry in ${ARCH_DIRS[$arch]}; do
    IFS='|' read -r dir variant <<< "$entry"
    while IFS=$'\t' read -r src dest; do
      [ -n "${src:-}" ] || continue
      cp -f "$src" "$stage/$dest"
    done < <(collect_assets "$dir" "$arch" "$variant")
  done

  # ------------------------------------------------------------- notes -----
  {
    echo "**SketchOpenSourceProject** $TAG for **$arch**"
    echo
    echo "A lightweight Android 16 build on LineageOS, with no Google apps, that"
    echo "installs and runs Debian \`.deb\` packages. dpkg runs inside a Debian"
    echo "chroot, and qemu-user makes the other architecture's packages work too."
    echo
    echo "Supported architectures: **arm64**, **amd64** - each has its own release."
    echo
    echo "### What is in this release"
    echo
    for src in "$stage"/*; do
      [ -f "$src" ] || continue
      dest="$(basename "$src")"
      line="$(describe_asset "$dest")"
      if [ -n "$line" ]; then
        echo "- \`$dest\` - $line"
      else
        echo "- \`$dest\`"
      fi
    done
    echo
    echo "### Boot it without installing anything"
    echo
    if [ -f "$stage/sketch-$arch.iso" ]; then
      echo '```'
      echo "qemu-system-x86_64 -m 1G -cdrom sketch-$arch.iso   # or boot it on bare metal"
      echo '```'
      echo
      echo "The medium is the Debian userland itself: it boots into a root shell with"
      echo "\`deb\` on PATH, and nothing is written to any disk."
      echo
    fi
    if [ -f "$stage/sketch-$arch-initrd.gz" ] && [ -f "$stage/sketch-$arch-vmlinuz" ]; then
      echo '```'
      echo "qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1500 \\"
      echo "  -kernel sketch-$arch-vmlinuz -initrd sketch-$arch-initrd.gz -nographic   # arm64"
      echo '```'
      echo
    fi
    echo "Then, inside it:"
    echo
    echo '```'
    echo "deb about"
    echo "deb install /root/sketch-hello_1.0_all.deb && sketch-hello"
    echo '```'
    echo
    echo "### Or use the runtime on a machine you already have"
    echo
    echo '```'
    echo "chmod +x sketchd-$arch"
    echo "SKETCH_BASE=/tmp/sketch ./sketchd-$arch rootfs init ./rootfs-$arch.tar.gz"
    echo "SKETCH_BASE=/tmp/sketch sudo ./sketchd-$arch install ./something.deb"
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

  if [ "$MODE" = "list" ]; then
    log "would publish $rel_tag ($title):"
    ( cd "$stage" && ls -1sh ./* | sed 's/^/    /' )
    rm -rf "$stage" "$notes"
    return 0
  fi

  if [ "$MODE" = "dry-run" ]; then
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
  local file
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

for arch in "${ARCH_LIST[@]}"; do
  publish_one "$arch"
done

if [ "$MODE" = "upload" ]; then
  log "all releases are up: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases"
fi
