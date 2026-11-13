#!/usr/bin/env bash
#
# Checks the host for the things a LineageOS 23 (Android 16) build needs.
# Nothing here is installed for you; it only reports.
#
set -uo pipefail

ok=0
warn=0

say() { printf '%s %s\n' "$1" "$2"; }
good() { say "  ok  " "$1"; }
bad() { say " FAIL " "$1"; ok=1; }
soft() { say " warn " "$1"; warn=1; }

printf '\n[sketch] host check (LineageOS 23 / Android 16)\n\n'

if [ "$(uname -s)" = "Linux" ]; then
  good "kernel: $(uname -sr)"
else
  bad "kernel: $(uname -s) - Android only builds on Linux (a VM or container will do)"
fi

case "$(uname -m)" in
  x86_64|aarch64) good "host arch: $(uname -m)" ;;
  *) bad "host arch: $(uname -m) - need x86_64 or aarch64" ;;
esac

# LineageOS is far kinder than AOSP here: 16 GiB builds a single device, 8 GiB
# works with a low job count. This is the point of not using a full AOSP tree.
mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024 ))
if [ "$mem_gb" -ge 16 ]; then
  good "RAM: ${mem_gb} GiB"
elif [ "$mem_gb" -ge 8 ]; then
  soft "RAM: ${mem_gb} GiB - build with JOBS=4 and expect swapping"
else
  bad "RAM: ${mem_gb} GiB - 8 GiB is the floor for one device"
fi

free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
free_gb=${free_gb:-0}
if [ "$free_gb" -ge 200 ]; then
  good "disk: ${free_gb} GiB free on /"
elif [ "$free_gb" -ge 120 ]; then
  soft "disk: ${free_gb} GiB free - enough for one device with ccache off"
else
  bad "disk: ${free_gb} GiB free - LineageOS plus out/ wants about 120-200 GiB"
fi

for tool in git curl python3 unzip zip rsync ccache; do
  if command -v "$tool" >/dev/null 2>&1; then
    good "$tool: $(command -v "$tool")"
  else
    case "$tool" in
      ccache) soft "$tool: missing (optional, but makes rebuilds much faster)" ;;
      *) bad "$tool: missing - sudo apt install $tool" ;;
    esac
  fi
done

if command -v repo >/dev/null 2>&1; then
  good "repo: $(command -v repo)"
else
  bad "repo: missing - see https://source.android.com/setup/develop#installing-repo"
fi

# The tree ships its own JDK in prebuilts/, so a host JDK is not required.
if command -v java >/dev/null 2>&1; then
  good "java: $(java -version 2>&1 | head -1)"
else
  soft "java: not on PATH - fine, prebuilts/jdk in the tree is used"
fi

if command -v debootstrap >/dev/null 2>&1; then
  good "debootstrap: $(command -v debootstrap) (for the Debian userland)"
else
  soft "debootstrap: missing - sudo apt install debootstrap (only for ./build.sh rootfs)"
fi

printf '\n'
if [ "$ok" -ne 0 ]; then
  printf '[sketch] blockers above must be fixed before ./build.sh sync\n\n'
  exit 1
fi
if [ "$warn" -ne 0 ]; then
  printf '[sketch] warnings only - you can go ahead\n\n'
else
  printf '[sketch] all good\n\n'
fi
