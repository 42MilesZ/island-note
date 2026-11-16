.PHONY: all build test test-resize test-all icons package package-dev install-local run notarize audit testflight

all: package

build:
	swift build -c release --product IslandNote

# FloatingResizeTests drives real panel animations and takes most of the
# suite's time; run it only for resize, pinch, drag or docking changes.
test:
	swift test --skip FloatingResizeTests

test-resize:
	swift test --filter FloatingResizeTests

test-all:
	swift test

icons:
	./scripts/update-icon.sh

# Stable Developer ID signing is the default; signing failures stop packaging.
package:
	./scripts/package.sh

# Disposable development builds only: do not use with a saved Flomo token.
package-dev:
	SIGN_IDENTITY=- ./scripts/package.sh

# Persistent local installs must retain a stable Keychain identity.
install-local: package
	./scripts/install-local.sh

run: package
	open .build/local-release.noindex/IslandNote.app

notarize: package
	./scripts/notarize.sh

audit:
	gitleaks git --log-opts=--all --redact=100

testflight:
	./scripts/testflight.sh
