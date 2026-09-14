.DEFAULT_GOAL := build

INSTALL_DIR ?= /Applications

.PHONY: build test run install dmg demo screenshots screenshots-context localize clean help

build:
	./scripts/bundle.sh

test:
	./scripts/check.sh

run: build
	open build/AIUsage.app

install:
	./scripts/install.sh --dest-dir "$(INSTALL_DIR)"

dmg: build
	./scripts/dmg.sh --no-build

demo: build
	AIUSAGE_DATA_DIR="$(CURDIR)/build/demo-data" build/AIUsage.app/Contents/MacOS/AIUsage --demo

screenshots: build
	AIUSAGE_DATA_DIR="$(CURDIR)/build/demo-data" build/AIUsage.app/Contents/MacOS/AIUsage --demo --render-demo

screenshots-context: build
	AIUSAGE_DATA_DIR="$(CURDIR)/build/demo-data" build/AIUsage.app/Contents/MacOS/AIUsage --demo --render-context

localize:
	python3 scripts/localize.py

clean:
	rm -rf .build build

help:
	@printf '%s\n' \
	  'make / make build    Build a signed release app in build/AIUsage.app' \
	  'make test            Check translations and run offline tests' \
	  'make run             Build and launch without installing' \
	  'make install         Build, install in /Applications and launch' \
	  '                     Override with INSTALL_DIR="$$HOME/Applications"' \
	  'make dmg             Build a drag-and-drop installer in build/' \
	  'make demo            Launch with sample data, without provider requests' \
	  'make screenshots     Render demo screenshots in build/demo-data/' \
	  'make screenshots-context  Capture demo popovers on the macOS desktop' \
	  'make localize        Regenerate translations from the String Catalog' \
	  'make clean           Remove build products and compiler caches'
