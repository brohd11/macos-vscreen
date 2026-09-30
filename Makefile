APP := build/VScreen.app
BIN := $(APP)/Contents/MacOS/vscreen
SOURCES := $(wildcard Sources/*.m)
SIGNING_IDENTITY ?= -
ARCHS ?=
CFLAGS := -fobjc-arc -fmodules -fmodules-cache-path=build/ModuleCache -Wall -Wextra -Werror -Wno-deprecated-declarations -mmacosx-version-min=14.0
YAML_OBJECTS := $(patsubst Vendor/libyaml/src/%.c,build/libyaml/%.o,$(wildcard Vendor/libyaml/src/*.c))
YAML_LIB := build/libyaml.a
# libyaml is vendored and statically linked, so the installed app has no runtime dependency on it.
YAML_CFLAGS := -O2 -w -mmacosx-version-min=14.0 -IVendor/libyaml/include -DYAML_VERSION_MAJOR=0 \
	-DYAML_VERSION_MINOR=2 -DYAML_VERSION_PATCH=5 -DYAML_VERSION_STRING='"0.2.5"'
# Stamped into `vscreen --version`; override with `make VERSION=...`.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
VERSION_STAMP := build/version.txt
# When the version differs from the last build's, drop the binary so it relinks. This runs at parse
# time because make 3.81 compares whole-second mtimes and would miss a stamp rewritten mid-build.
ifneq ($(VERSION),$(shell cat $(VERSION_STAMP) 2>/dev/null))
$(shell mkdir -p build && echo '$(VERSION)' > $(VERSION_STAMP) && rm -f $(BIN))
endif
FRAMEWORKS := -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework Carbon -framework ServiceManagement

.PHONY: all run test integration install clean
all: $(BIN)

ICONS := Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png
PRESETS := $(wildcard presets/*/*/*)

build/libyaml/%.o: Vendor/libyaml/src/%.c Vendor/libyaml/src/yaml_private.h Vendor/libyaml/include/yaml.h Makefile
	mkdir -p build/libyaml
	xcrun clang $(YAML_CFLAGS) $(foreach a,$(ARCHS),-arch $(a)) -c $< -o $@

$(YAML_LIB): $(YAML_OBJECTS)
	rm -f $@ && xcrun libtool -static -o $@ $^

$(BIN): $(SOURCES) $(wildcard Sources/*.h) $(YAML_LIB) Resources/Info.plist $(ICONS) $(PRESETS) Makefile
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	xcrun clang $(CFLAGS) -DVS_VERSION='"$(VERSION)"' -IVendor/libyaml/include $(foreach a,$(ARCHS),-arch $(a)) $(SOURCES) $(YAML_LIB) $(FRAMEWORKS) -o $@
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(ICONS) $(APP)/Contents/Resources/
	rm -rf $(APP)/Contents/Resources/presets && cp -R presets $(APP)/Contents/Resources/
	codesign --force --sign "$(SIGNING_IDENTITY)" --identifier local.vscreen $(APP)
	ln -sf VScreen.app/Contents/MacOS/vscreen build/vscreen

run: all
	build/vscreen --new Desktop1

test: all
	python3 Tests/cli.py
	python3 Tests/examples.py

integration: all
	python3 Tests/integration.py

install: all
	sh scripts/install.sh "$(APP)"

clean:
	rm -rf build
