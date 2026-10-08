.PHONY: all build icons package package-dev run notarize audit testflight

all: package

build:
	swift build -c release --product IslandNote

icons:
	./scripts/update-icon.sh

# Stable Developer ID signing is the default; signing failures stop packaging.
package:
	./scripts/package.sh

# Disposable development builds only: do not use with a saved Flomo token.
package-dev:
	SIGN_IDENTITY=- ./scripts/package.sh

run: package
	open IslandNote.app

notarize: package
	./scripts/notarize.sh

audit:
	gitleaks git --log-opts=--all --redact=100

testflight:
	./scripts/testflight.sh
