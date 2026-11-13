# Everything SketchOpenSourceProject adds to the image, shared by both
# architectures.
#
# This file is always included from vendor/sketch, so the paths below are
# relative to the top of the LineageOS tree and the link made by
# scripts/link-vendor.sh.

# --- the .deb runtime -------------------------------------------------------
# Installs /system_ext/bin/sketchd and the `deb` symlink next to it.
PRODUCT_PACKAGES += \
    sketchd

# --- the Debian userland ----------------------------------------------------
# ./build.sh rootfs leaves a tarball behind; when it exists it is embedded in
# /system_ext/sketch/ and `deb rootfs init` unpacks it. Without it, push one to
# /data/sketch/rootfs-<arch>.tar.gz instead.
SKETCH_ROOTFS_ARM64 := $(wildcard vendor/sketch/rootfs/prebuilt/rootfs-arm64.tar.gz)
SKETCH_ROOTFS_AMD64 := $(wildcard vendor/sketch/rootfs/prebuilt/rootfs-amd64.tar.gz)

ifneq ($(SKETCH_ROOTFS_ARM64),)
PRODUCT_COPY_FILES += \
    $(SKETCH_ROOTFS_ARM64):$(TARGET_COPY_OUT_SYSTEM_EXT)/sketch/rootfs-arm64.tar.gz
endif

ifneq ($(SKETCH_ROOTFS_AMD64),)
PRODUCT_COPY_FILES += \
    $(SKETCH_ROOTFS_AMD64):$(TARGET_COPY_OUT_SYSTEM_EXT)/sketch/rootfs-amd64.tar.gz
endif

# --- build identity ---------------------------------------------------------
# ro.* is read-only and set at build time; the debloat pass sets the rest.
PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.sketch.version=1.0 \
    ro.sketch.name=SketchOpenSourceProject \
    ro.sketch.debloat=true \
    ro.sketch.autostart=1

# --- SELinux ---------------------------------------------------------------
# system_ext private policy: the sketchd domain and its file types.
PRODUCT_PRIVATE_SEPOLICY_DIRS += vendor/sketch/sepolicy

# --- first boot is not a compiler job --------------------------------------
# Verify-only dexopt keeps a lightweight image out of a long first-boot dex2oat
# run; apps still get optimised in the background afterwards.
PRODUCT_PRODUCT_PROPERTIES += \
    pm.dexopt.first-boot=verify \
    pm.dexopt.boot-after-ota=verify
