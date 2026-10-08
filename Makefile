.PHONY: build test unit e2e test-bundle test-release live-check app release run icon clean

build:
	swift build

test:
	scripts/test.sh

unit:
	scripts/test.sh --filter ATermCoreTests

e2e:
	scripts/test.sh --filter 'ATermE2ETests|ATermModalTests'

test-bundle:
	scripts/test-bundle.sh

# Signs, notarizes and staples for real: needs the Developer ID identity and the notarytool profile.
test-release:
	scripts/test-release.sh

# Needs OPENROUTER_API_KEY in the environment; spends free-tier requests.
live-check:
	ATERM_LIVE=1 scripts/test.sh --filter ATermLiveTests

app:
	scripts/bundle.sh

# Developer ID signature, notarization and staple: dist/ATerm-<version>.zip and its release notes.
release:
	scripts/release.sh

run: app
	open build/ATerm.app

icon:
	scripts/make-icon.sh

clean:
	rm -rf .build build dist
