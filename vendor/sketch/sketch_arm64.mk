# arm64 (aarch64) SketchOpenSourceProject product.
#
# The device tree it builds on top of. The default is LineageOS' generic arm64
# target, which boots in the emulator and on a few dev boards. To get this on
# real hardware, point it at that phone's LineageOS device tree, either in this
# file or on the command line:
#
#   SKETCH_BASE_ARM64 := device/samsung/starqltechn/lineage_starqltechn.mk
#   make -j8 SKETCH_BASE_ARM64=device/.../lineage_....mk
#
# The board config, kernel, HALs and ABI come from there; this project only adds
# the .deb runtime and the debloat pass.
SKETCH_BASE_ARM64 ?= device/generic/arm64/lineage_arm64.mk

ifeq ($(wildcard $(SKETCH_BASE_ARM64)),)
# Older and newer LineageOS trees name the generic arm64 product differently.
SKETCH_BASE_ARM64 := device/generic/arm64/aosp_arm64.mk
endif

ifeq ($(wildcard $(SKETCH_BASE_ARM64)),)
$(error SketchOpenSourceProject: no base product at $(SKETCH_BASE_ARM64). Set SKETCH_BASE_ARM64 to your device's LineageOS product makefile.)
endif

$(call inherit-product, $(SKETCH_BASE_ARM64))
$(call inherit-product, vendor/sketch/debloat.mk)
$(call inherit-product, vendor/sketch/sketch_product.mk)

# PRODUCT_DEVICE stays whatever the base product set: this is a layer, not a
# device tree.
PRODUCT_NAME := sketch_arm64
PRODUCT_BRAND := SketchOpenSourceProject
PRODUCT_MODEL := SketchOpenSourceProject arm64
PRODUCT_MANUFACTURER := SketchOpenSourceProject
