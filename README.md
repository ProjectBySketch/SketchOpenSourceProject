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
./build.sh env                  # check the host first
./build.sh sync                 # repo init/sync LineageOS into ~/lineage
./build.sh rootfs both          # Debian userland for arm64 and amd64
./build.sh build arm64          # sketch_arm64-userdebug
./build.sh build amd64          # sketch_x86_64-userdebug
```

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

## Where the built files come from

AOSP-class images cannot be compiled on a phone, and an image set is gigabytes:
the images, the ISO and the binaries are **build outputs, not source**, so they
live on the repository's **Releases** page rather than in git. Two ways to fill
it:

**On your own Linux machine:**

```
./build.sh env && ./build.sh sync
./build.sh rootfs both
./build.sh build arm64 && ./build.sh artifacts arm64
./build.sh build amd64 && ./build.sh artifacts amd64
./build.sh publish v1.0 --list     # see exactly what would go up
./build.sh publish v1.0            # needs `gh auth login`
```

**Each architecture gets its own release**, so a download is never ambiguous:

- `v1.0-arm64` - `sketch-arm64-userdebug.zip`, `sketchd-arm64`,
  `rootfs-arm64.tar.gz` and the raw `*.img` files
- `v1.0-amd64` - `sketch-amd64-userdebug.zip`, `sketch-amd64.iso`,
  `sketchd-amd64`, `rootfs-amd64.tar.gz` and the raw `*.img` files

An architecture is only published when `dist/` really holds its images - a
missing build is an error, never an empty release. `--list` prints what each
release would carry; `--dry-run` does everything except upload.

**Through GitHub Actions**, which does the same thing on a machine of yours.
The workflow has two halves:

- **`verify` runs on GitHub's own hosted runners, free, on every push.** It
  cannot build an image, but it checks the things that actually break: every
  shell script parses, the workflow YAML is valid, the makefiles and
  `Android.bp` point at files that exist, and **the `sketchd` daemon compiles,
  links and runs**. That is the highest-risk code here, so it is worth having on
  every commit.
- **`sync` -> `build` -> `release` is the real image build**, on a
  **self-hosted** runner, because a hosted one has neither the disk nor the
  hours. It only runs when you ask (*Actions -> build -> Run workflow*) or when
  you push a tag, so an ordinary push never queues work nobody can serve:

```
# on the build machine, once
./config.sh --labels self-hosted,linux,aosp
```

Then *Actions -> build -> Run workflow*, tick `publish`, and the releases appear.
Each `dist/sketch-<arch>-<variant>/` holds:

- `*.img` - every image the build made (system, boot, system_ext, super, ...)
- `sketch-<arch>-<variant>.zip` - unzip and `fastboot flashall`
- `sketch-amd64.iso` - bootable live medium for amd64
- `bin/sketchd`, `bin/rootfs-<arch>.tar.gz` - the runtime and its Debian userland
- `manifest.txt`, `SHA256SUMS` - what it is, and how to verify it

Assets over GitHub's 2 GiB limit are split into `.partNN` pieces; join them with
`cat name.part* > name`.

## Layout

- `build.sh` - the driver: `env`, `sync`, `rootfs`, `build`, `both`, `artifacts`, `publish`
- `scripts/` - host checks, LineageOS sync, vendor link, userland, artifacts, release
- `scripts/publish-release.sh` - one GitHub release per architecture
- `.github/workflows/build.yml` - CI: hosted `verify`, self-hosted image build
- `vendor/sketch/AndroidProducts.mk` - the two lunch targets
- `vendor/sketch/sketch_arm64.mk`, `sketch_x86_64.mk` - base product + layer
- `vendor/sketch/sketch_product.mk` - packages, userland embedding, properties
- `vendor/sketch/debloat.mk` - what is stripped
- `vendor/sketch/sketchd/` - the daemon and CLI (`sketchd`, `deb`)
- `vendor/sketch/sepolicy/` - the `sketchd` domain

## Status

The source is written and reviewed; the images have not been built yet. There is
no compiler on the device this was authored on, so the first `./build.sh sync` /
`./build.sh build` (or the first CI run) is where the build gets proven. The
SELinux policy is deliberately `permissive sketchd` bring-up policy - it is the
piece most likely to need adjusting against a real device, and the piece to
tighten before shipping.
