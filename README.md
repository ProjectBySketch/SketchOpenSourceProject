# SketchOpenSourceProject

A lightweight Android 16 build that installs and runs Debian `.deb` packages,
for **arm64** (real hardware) and **amd64** (emulator, x86 boxes).

It is built on **LineageOS 23**, not on raw AOSP, for two reasons that matter:

- **No Google apps to strip.** LineageOS ships without GMS, Play Services or the
  Play Store, so the image is clean before this project touches it. Nothing here
  adds them back - `WITH_GMS` is never set.
- **It builds on hardware people actually have.** The sync is a fraction of
  AOSP's, and one device builds in 16 GiB of RAM (8 GiB works with `JOBS=4`)
  against a 250 GiB disk. A full AOSP tree wants 32 GiB and 400 GiB.

Two products:

- `sketch_arm64` - arm64 device builds
- `sketch_x86_64` - the amd64 target, i.e. what you run in the emulator

## How .deb support works

No glibc-on-Android tricks, no reimplemented dpkg. The image gets a real Debian
userland and hands the work to it:

- `./build.sh rootfs` builds a minimal Debian (minbase) userland with
  `debootstrap`, including `dpkg`, `apt` and `qemu-user-static`, and packs it
  into `vendor/sketch/rootfs/prebuilt/rootfs-<arch>.tar.gz`.
- The tarball is embedded at `/system_ext/sketch/` in the image.
- `deb rootfs init` unpacks it into `/data/sketch/rootfs` (first use; a minute).
- `deb install foo.deb` copies the package in and runs `dpkg -i` **inside the
  chroot**, with `/dev`, `/proc` and `/sys` bind-mounted. So `gz`, `xz` and
  `zstd` packages, dependencies, `preinst`/`postinst` and `dpkg --purge` all
  behave exactly as on Debian.

### arm and amd64 at once

`binfmt_misc` plus the `qemu-*-static` binaries inside the userland mean a
package for the *other* architecture still runs: an arm64 image runs amd64
`.debs` through `qemu-x86_64-static`, and an amd64 image runs arm64 `.debs`
through `qemu-aarch64-static`. Check what the current image can do with
`deb arch`. Cross-arch packages are interpreted, so expect them to be noticeably
slower; install the native build of anything heavy.

## What "debloat" means here

Two layers. LineageOS already excludes every Google app. Then
`vendor/sketch/debloat.mk` filters the stock AOSP apps out of `PRODUCT_PACKAGES`
after the base product is inherited, and turns off the first-run noise: browser,
calendar, camera, clock, email, music, print stack, settings intelligence, quick
search, wallpaper and live-wallpaper pickers, bookmarks providers, STK, WAPPush,
Protips, Traceur; setup wizard disabled, checkin off, verify-only dexopt so
first boot is not a compiler job. `deb debloat` lists it on the device, and
`ro.sketch.debloat=1` marks the image.

To keep something, delete its line. To remove more, add the module name.
`filter-out` silently ignores names your tree does not have, so this list cannot
break a build across releases.

## Quick start

On a Linux host with `repo`, git and about 250 GiB free:

```
bash build.sh env               # check the host first
bash build.sh sync              # repo init/sync LineageOS into ~/lineage
bash build.sh rootfs both       # Debian userland for arm64 and amd64
bash build.sh build arm64       # sketch_arm64-userdebug
bash build.sh build amd64       # sketch_x86_64-userdebug
```

`bash build.sh` rather than `./build.sh` because the scripts in this repository
were authored without the executable bit. One `chmod +x build.sh scripts/*.sh`
fixes that permanently; until then every command works the same either way.

`sync` symlinks this repository into the tree as `vendor/sketch`, so you keep
editing here and the build sees it there. `AOSP_DIR` and `LINEAGE_BRANCH`
override the defaults (`~/lineage`, `lineage-23.0`).

## On the device

```
adb root
deb about                       # what this build is
deb arch                        # host arch, userland state, cross-arch support
deb rootfs init                 # unpack the embedded userland (once)
deb install ./hello_2.10_arm64.deb
deb run hello
deb list
deb info hello
deb remove hello
deb shell
```

`deb shell` and `deb run` need a terminal, so they always run in-process; the
other commands go through `sketchd` (started at boot by init) when it is up, and
fall back to doing the work directly when it is not. `setprop ro.sketch.autostart
0` before boot keeps the daemon off entirely.

## Putting it on real hardware

This is a product layer, not a device tree: it inherits whatever you point it at
and adds the `.deb` runtime on top. Point it at your phone's LineageOS product:

```
SKETCH_BASE_ARM64 := device/acme/widget/lineage_widget.mk
```

or `make -j8 SKETCH_BASE_ARM64=device/acme/widget/lineage_widget.mk`. The
default is LineageOS' generic arm64 target, which boots in the emulator but is
not a phone image. Getting the device tree in is the usual LineageOS
`.repo/local_manifests/` business.

## Running it without an image

The `.deb` feature is not an image. It is one binary (`sketchd`) plus a Debian
userland tarball, so it runs anywhere Linux does. No ISO, no emulator, no
flashing, no 250 GiB build.

**Boot it.** `bash build.sh dist amd64` builds a medium that does not need
Android at all: the Debian userland packed as an initramfs, with `sketchd`
inside, wrapped in a GRUB ISO (BIOS + UEFI) and a UEFI disk image. Boot it and
you are root in a Debian shell with `deb` on PATH. Nothing is written to a disk -
the system lives in memory - so `deb install` works on a machine with no free
space and no installation:

```
bash build.sh dist amd64            # -> dist/sketch-amd64-live/
qemu-system-x86_64 -m 1G -cdrom dist/sketch-amd64-live/sketch-amd64.iso
# or: dd if=dist/sketch-amd64-live/sketch-amd64-live.img of=/dev/sdX bs=4M
```

arm64 has no ISO route here (GRUB cannot make one), so it ships the pair:
`sketch-arm64-vmlinuz` and `sketch-arm64-initrd.gz`, which any arm64 kernel can
boot:

```
qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1500 -nographic \
  -kernel dist/sketch-arm64-live/sketch-arm64-vmlinuz \
  -initrd dist/sketch-arm64-live/sketch-arm64-initrd.gz
```

**On any Linux machine**, without booting anything - this compiles the real
daemon, builds a real Debian userland with `debootstrap`, then builds a real
`.deb` with `dpkg-deb`, installs it, runs it inside the chroot, lists it and
removes it:

```
bash scripts/run-local.sh build      # compile sketchd
bash scripts/run-local.sh demo       # userland + a real package, end to end
```

Everything lands in `.local-run/` and nothing on the host is touched. The
unpack and install steps re-exec through `sudo`, because a chroot and bind
mounts need root. Individual steps, and any CLI verb, are available too:

```
bash scripts/run-local.sh userland   # just build the Debian userland
bash scripts/run-local.sh init       # unpack it via `sketchd rootfs init`
bash scripts/run-local.sh deb list   # any `deb` command
bash scripts/run-local.sh shell      # a shell inside the userland
```

This is exactly what CI does on every push, on a GitHub-hosted runner, so the
claim is tested rather than asserted.

**On a phone you already have**, rooted (userdebug build or Magisk) - the same
runtime, pushed onto the device:

```
export ANDROID_NDK_HOME=/path/to/ndk
bash scripts/install-onto-device.sh            # or --serial <device>
```

It cross-compiles `sketchd` for the device ABI, pushes it and a userland tarball
to `/data/sketch`, then runs `deb about`, `deb rootfs init` and `deb arch` to
prove it. From then on `su -c '/data/sketch/bin/deb install foo.deb'` works on
that phone. That is the feature working on real hardware without building a ROM.

What you *cannot* do without a build is have this as your phone's actual system
image - debloated, with `deb` on `PATH` out of the box. That still needs
`bash build.sh build <arch>`, or the CI runner.

## Where the built files come from

AOSP-class images cannot be compiled on a phone, and an image set is gigabytes:
the images, the ISO and the binaries are **build outputs, not source**, so they
live on the repository's **Releases** page rather than in git.

**CI builds and publishes them, on GitHub's own runners.** The `runtime` job
needs no LineageOS tree: it compiles `sketchd` for **amd64** and **arm64**,
builds the Debian userland for both (arm64 through qemu-user), assembles the
bootable media, then **boots it in QEMU and installs a `.deb` inside it** before
publishing. One release per architecture:

- `latest-arm64` (or `v1.0-arm64` for a tag) - `sketchd-arm64`,
  `rootfs-arm64.tar.gz`, `sketch-arm64-vmlinuz`, `sketch-arm64-initrd.gz`
- `latest-amd64` - the same, plus `sketch-amd64.iso` and `sketch-amd64-live.img`

Every asset is checked by the job that made it: the boot test asserts that the
medium reaches a shell, runs `deb about`, installs the package it ships and runs
it. A release is only made when that passed.

**On your own Linux machine**, the same thing, plus the Android images if you
have the tree:

```
bash build.sh env && bash build.sh sync
bash build.sh rootfs both
bash build.sh dist amd64 && bash build.sh dist arm64   # runtime + bootable media
bash build.sh build arm64 && bash build.sh artifacts arm64
bash build.sh build amd64 && bash build.sh artifacts amd64
bash build.sh publish v1.0 --list     # see exactly what would go up
bash build.sh publish v1.0            # needs `gh auth login`
```

`dist/` may hold both an image build and a runtime build for one architecture;
they are merged into that architecture's release, and an architecture with
nothing in it is an error, never an empty release. `--list` prints what each
release would carry; `--dry-run` does everything except upload.

**The Android image stays self-hosted.** `sync` -> `build` -> `image-release`
needs a machine with the LineageOS tree, ~250 GiB free and hours to spare, so it
only runs on a self-hosted runner, and only when asked (*Actions -> build -> Run
workflow*, tick `publish`) or on a tag:

```
# on the build machine, once
./config.sh --labels self-hosted,linux,aosp
```

Each `dist/sketch-<arch>-<variant>/` holds:

- `*.img` - every image the build made (system, boot, system_ext, super, ...)
- `sketch-<arch>-<variant>.zip` - unzip and `fastboot flashall`
- `sketch-amd64.iso` - bootable live medium for amd64
- `bin/sketchd`, `bin/rootfs-<arch>.tar.gz` - the runtime and its Debian userland
- `manifest.txt`, `SHA256SUMS` - what it is, and how to verify it

Assets over GitHub's 2 GiB limit are split into `.partNN` pieces; join them with
`cat name.part* > name`.

## Layout

- `build.sh` - the driver: `env`, `sync`, `rootfs`, `build`, `both`, `artifacts`, `dist`, `publish`, `run`, `device`
- `scripts/` - host checks, LineageOS sync, vendor link, userland, artifacts, release
- `scripts/build-dist.sh` - the runtime, the userland and the bootable media into `dist/`, no Android tree
- `scripts/build-runtime.sh` - `sketchd` for amd64 and arm64 (native or cross)
- `scripts/make-live.sh` - the bootable ISO, UEFI disk image and initramfs
- `scripts/run-local.sh` - run the `.deb` runtime here, no image needed
- `scripts/install-onto-device.sh` - push it onto an already-rooted phone
- `scripts/publish-release.sh` - one GitHub release per architecture
- `.github/workflows/build.yml` - CI: hosted `verify`, self-hosted image build
- `vendor/sketch/AndroidProducts.mk` - the two lunch targets
- `vendor/sketch/sketch_arm64.mk`, `sketch_x86_64.mk` - base product + layer
- `vendor/sketch/sketch_product.mk` - packages, userland embedding, properties
- `vendor/sketch/debloat.mk` - what is stripped
- `vendor/sketch/sketchd/` - the daemon and CLI (`sketchd`, `deb`)
- `vendor/sketch/sepolicy/` - the `sketchd` domain

## Status

The `.deb` runtime is compiled, linked and exercised end to end by CI on every
push: a real Debian userland, a real `.deb`, installed, run, listed and removed.
Hosted CI also builds the bootable media for **amd64 and arm64**, boots it in
QEMU, installs a `.deb` from inside it and runs the result - and publishes it to
the Releases page, one release per architecture.

What has *not* been built is the Android image itself - there is no LineageOS
tree on the device this was authored on, so the first `bash build.sh sync` /
`bash build.sh build` is where the image gets proven. The SELinux policy is
deliberately `permissive sketchd` bring-up policy: it is the piece most likely to
need adjusting against a real device, and the piece to tighten before shipping.
