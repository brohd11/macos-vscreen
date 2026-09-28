APP := build/VScreen.app
BIN := $(APP)/Contents/MacOS/vscreen
SOURCES := $(wildcard Sources/*.m)
SIGNING_IDENTITY ?= -
ARCHS ?=
CFLAGS := -fobjc-arc -fmodules -fmodules-cache-path=build/ModuleCache -Wall -Wextra -Werror -Wno-deprecated-declarations -mmacosx-version-min=14.0
FRAMEWORKS := -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit -framework CoreMedia -framework QuartzCore -framework Carbon

.PHONY: all run test integration install clean
all: $(BIN)

ICONS := Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png

$(BIN): $(SOURCES) $(wildcard Sources/*.h) Resources/Info.plist $(ICONS) Makefile
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	xcrun clang $(CFLAGS) $(foreach a,$(ARCHS),-arch $(a)) $(SOURCES) $(FRAMEWORKS) -o $@
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(ICONS) $(APP)/Contents/Resources/
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
