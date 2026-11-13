# SketchOpenSourceProject debloat pass.
#
# LineageOS already ships without any Google apps - that is most of the work
# this file would otherwise have to do. What is left is the stock AOSP app set
# and the first-run noise a lightweight image does not need.
#
# Included straight after the base product, so PRODUCT_PACKAGES already holds
# everything inherited. filter-out is a no-op for names your tree does not have,
# so a module that moved between releases cannot break the build - it just does
# nothing. Check what is actually in the image with:
#   ls out/target/product/*/system/app out/target/product/*/system/priv-app
#
# To keep a package, delete its line. To drop more, add its module name.

# --- apps a lightweight image does not need --------------------------------
SKETCH_REMOVED_APPS := \
    BasicDreams \
    BookmarkProvider \
    Browser2 \
    Calendar \
    Camera2 \
    CellBroadcastService \
    CompanionDeviceManager \
    DeskClock \
    EasterEgg \
    Email \
    Galaxy4 \
    HoloSpiralWallpaper \
    HTMLViewer \
    LiveWallpaperPicker \
    Music \
    MusicFX \
    NoiseField \
    PartnerBookmarksProvider \
    PhaseBeam \
    PhotoTable \
    PrintRecommendationService \
    PrintSpooler \
    Protips \
    QuickSearchBox \
    SettingsIntelligence \
    SharedStorageBackup \
    SoundPicker \
    Stk \
    Traceur \
    UserDictionaryProvider \
    WAPPushManager \
    WallpaperPicker

# --- debug and bring-up tooling, gone from user builds ---------------------
ifeq ($(TARGET_BUILD_VARIANT),user)
SKETCH_REMOVED_APPS += \
    Development \
    SdkSetup \
    SimAppDialog
endif

PRODUCT_PACKAGES := $(filter-out $(SKETCH_REMOVED_APPS),$(PRODUCT_PACKAGES))

# --- telemetry and first-run noise off -------------------------------------
PRODUCT_PRODUCT_PROPERTIES += \
    ro.setupwizard.mode=DISABLED \
    ro.config.nocheckin=1 \
    ro.com.android.dataroaming=false \
    ro.kernel.android.checkjni=0 \
    persist.sys.disable_rescue=true \
    persist.sys.strictmode.disable=true \
    dalvik.vm.dex2oat-filter=verify \
    dalvik.vm.image-dex2oat-filter=speed
