# SketchOpenSourceProject product definition.
#
# Two products, one per architecture:
#   sketch_arm64   - real arm64 hardware
#   sketch_x86_64  - the emulator and x86_64 boxes (the "amd64" target)
#
# They differ only in which LineageOS generic target they inherit; everything
# SketchOpenSourceProject adds is shared in sketch_product.mk.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/sketch_arm64.mk \
    $(LOCAL_DIR)/sketch_x86_64.mk

COMMON_LUNCH_CHOICES := \
    sketch_arm64-userdebug \
    sketch_arm64-user \
    sketch_x86_64-userdebug \
    sketch_x86_64-user
