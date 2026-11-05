.DEFAULT_GOAL := help

PYTHON ?= python3
override VERSION_FILE := $(strip $(shell cat VERSION 2>/dev/null))
VERSION ?= $(VERSION_FILE)

ifeq ($(VERSION_FILE),)
$(error VERSION file is missing or empty)
endif
ifneq ($(VERSION),$(VERSION_FILE))
$(error VERSION=$(VERSION) must match VERSION file ($(VERSION_FILE)); update VERSION in source first)
endif

CODESIGN_IDENTITY ?= Developer ID Application: Matti Vilola (MM233FKU38)
NOTARY_KEYCHAIN_PROFILE ?= lean-vs-code
SPARKLE_KEYCHAIN_ACCOUNT ?= LeanTerm
export VERSION CODESIGN_IDENTITY NOTARY_KEYCHAIN_PROFILE SPARKLE_KEYCHAIN_ACCOUNT

.PHONY: help build run test doctor release release-prepared publish install

help:
	@printf '%s\n' \
	  'build    Build the local ad-hoc development app' \
	  'run      Build and open the local development app' \
	  'test     Run release-helper and Swift core tests' \
	  'doctor   Check release tools, signing, notary, and Sparkle keys' \
	  'release  Build, sign, notarize, staple, and stage a release ZIP/appcast' \
	  'release-prepared Sign a validated release app already in dist/Lean Term.app' \
	  'publish  Upload verified artifacts to a draft GitHub release, then publish' \
	  'install  Install the staged release at /Applications/Lean Term.app'

build:
	./script/build_and_run.sh --build-only

run:
	./script/build_and_run.sh run

test:
	$(PYTHON) -m unittest script.test_release
	$(PYTHON) -m unittest discover -s benchmarks -p 'test_*.py'
	./script/build_and_run.sh --test

doctor:
	$(PYTHON) script/release.py doctor --version "$(VERSION)"

release:
	$(PYTHON) script/release.py release --version "$(VERSION)"

release-prepared:
	$(PYTHON) script/release.py release --prepared-app --version "$(VERSION)"

publish:
	$(PYTHON) script/release.py publish --version "$(VERSION)"

install:
	$(PYTHON) script/release.py install --version "$(VERSION)"
