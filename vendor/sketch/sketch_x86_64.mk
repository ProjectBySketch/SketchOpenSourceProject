# amd64 (x86_64) SketchOpenSourceProject product - the emulator target and x86
# boxes. Same layering as sketch_arm64.mk: this only picks the base product.

SKETCH_BASE_X86_64 ?= device/generic/x86_64/lineage_x86_64.mk

ifeq ($(wildcard $(SKETCH_BASE_X86_64)),)
SKETCH_BASE_X86_64 := device/generic/x86_64/aosp_x86_64.mk
endif

ifeq ($(wildcard $(SKETCH_BASE_X86_64)),)
$(error SketchOpenSourceProject: no base product at $(SKETCH_BASE_X86_64). Set SKETCH_BASE_X86_64 to your x86_64 product makefile.)
endif

$(call inherit-product, $(SKETCH_BASE_X86_64))
$(call inherit-product, vendor/sketch/debloat.mk)
$(call inherit-product, vendor/sketch/sketch_product.mk)

PRODUCT_NAME := sketch_x86_64
PRODUCT_BRAND := SketchOpenSourceProject
PRODUCT_MODEL := SketchOpenSourceProject amd64
PRODUCT_MANUFACTURER := SketchOpenSourceProject
