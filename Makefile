APP_NAME := IslandNote
BUILD_DIR := .build
RELEASE_DIR := $(BUILD_DIR)/release
APP := $(APP_NAME).app
CONTENTS := $(APP)/Contents

.PHONY: all build package run clean

all: package

build:
	swift build -c release

package: build
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(RELEASE_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign - $(APP) 2>/dev/null || true
	@echo "Built $(APP)"

run: package
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) $(APP)
