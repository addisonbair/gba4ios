O_RELEASE := 1
O_LTO := 1
android_minSDK := 4
-include config.mk
include $(IMAGINE_PATH)/make/android-armv6-gcc.mk
include build.mk
