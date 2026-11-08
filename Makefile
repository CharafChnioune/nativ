.PHONY: build verify clean
.PHONY: xcode-generate xcode-build xcode-sign xcode-run xcode-smoke xcode-lifecycle-smoke

XCODE_DERIVED_DATA ?= build/NativDevelopmentDerivedData
XCODE_BUILD_JOBS ?= 3
NATIV_FORK_REVISION ?= $(shell git rev-parse --verify HEAD 2>/dev/null || echo development)
ifneq ($(shell git status --porcelain --untracked-files=normal 2>/dev/null),)
NATIV_FORK_REVISION := $(NATIV_FORK_REVISION)-dirty
endif
# Build-product name; must match NATIV_PRODUCT_NAME in the xcconfig chain.
# Override to give a worktree its own app bundle, e.g.
#   make xcode-run NATIV_PRODUCT_NAME=nativ-trace
NATIV_PRODUCT_NAME ?= Nativ
NATIV_APP := $(XCODE_DERIVED_DATA)/Build/Products/Debug/$(NATIV_PRODUCT_NAME).app
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py

verify:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --verify-only

verify-python:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --skip-install --verify-only

clean:
	rm -rf build dist

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
	xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) -jobs $(XCODE_BUILD_JOBS) NATIV_PRODUCT_NAME=$(NATIV_PRODUCT_NAME) NATIV_FORK_REVISION=$(NATIV_FORK_REVISION) CODE_SIGNING_ALLOWED=NO build

xcode-sign: xcode-build
	./scripts/sign_macos_debug.sh $(abspath $(NATIV_APP))

xcode-run: xcode-sign
	./scripts/open_macos_debug.sh $(abspath $(NATIV_APP))

xcode-smoke: xcode-build
	$(NATIV_APP)/Contents/MacOS/$(NATIV_PRODUCT_NAME) --smoke-test

xcode-lifecycle-smoke: xcode-build
	$(NATIV_APP)/Contents/MacOS/$(NATIV_PRODUCT_NAME) --lifecycle-smoke-test

.PHONY: xcode-local-run
# Explicit development route without an owner signing certificate. Never publish this bundle.
xcode-local-run: xcode-build
	python3 scripts/sign_macos_local.py $(abspath $(NATIV_APP))
	NATIV_ALLOW_ADHOC_DEVELOPMENT=YES ./scripts/open_macos_debug.sh $(abspath $(NATIV_APP))
