# Makefile for building and packaging the VSCode Schematic Visualizer extension
#
# Design: two separate dependency strategies coexist here.
#
#   RUN targets  (web-run, linux-run-debug, linux-run-release)
#     Only ensure JS/native assets are staged, then hand off to `flutter run`.
#     Flutter's own incremental compiler + hot reload handles Dart changes,
#     so Make must NOT depend on $(DART_SOURCES) on this path.
#
#   PACKAGE targets  (extension, install-remote, install)
#     Must produce a build artifact (build/web/) that reflects the CURRENT
#     Dart sources before it gets zipped into the extension.  Stamp files
#     (build/.web-stamp, build/.linux-stamp) record the last successful
#     `flutter build` and depend on $(DART_SOURCES) so that any source
#     edit invalidates the stamp and forces a rebuild on the next package.
#
#   BUILD targets  (web, linux, web-debug, linux-debug, etc.)
#     Explicit "build me now" commands.  These go through the stamp so they
#     also track Dart sources -- if you just edited code and type `make web`,
#     it rebuilds.

ROOT := $(abspath $(CURDIR))
FLUTTER ?= flutter
NODE ?= node

# Source file patterns for dependency tracking
DART_SOURCES := $(shell find $(ROOT)/lib -name '*.dart' 2>/dev/null)
JS_BRIDGE_SOURCES := $(shell find $(ROOT)/js_bridge -name '*.js' 2>/dev/null)
JS_ASSETS := $(shell find $(ROOT)/assets/js -type f 2>/dev/null)

# Source of truth: extract version from pubspec.yaml
PUBSPEC_VERSION := $(shell grep '^version:' $(ROOT)/pubspec.yaml | head -1 | sed 's/version: *//' | sed 's/+.*//')

# Read name from package.json; version comes from pubspec.yaml
PKG_NAME := $(shell $(NODE) -p "require('./package.json').name")
PKG_VERSION := $(PUBSPEC_VERSION)
# Deterministic filenames produced by scripts
SLIM_ZIP := $(ROOT)/build/$(PKG_NAME)-$(PKG_VERSION)-slim.zip
VSIX := $(ROOT)/build/$(PKG_NAME)-$(PKG_VERSION).vsix

.PHONY: all help build extension vsix package clean real-clean install-local install-remote install web web-debug web-release linux linux-debug linux-release web-run web-serve linux-run-debug linux-run-profile linux-run-release clean-extension clean-web clean-linux force test coverage coverage-view coverage-clean coverity coverity-setup coverity-clean sync-version verify-elk-distribution

help:
	@echo "ROHD Schematic Visualizer Extension - Build Targets"
	@echo ""
	@echo "Extension Build Targets:"
	@echo "  all              - Build the extension (default target)"
	@echo "  extension        - Build VSCode extension"
	@echo "  build            - (alias for extension)"
	@echo ""
	@echo "Web Build Targets:"
	@echo "  web              - Build Flutter web app (default mode)"
	@echo "  web-debug        - Build Flutter web app (debug, forces rebuild)"
	@echo "  web-release      - Build Flutter web app (release, forces rebuild)"
	@echo ""
	@echo "Linux Build Targets:"
	@echo "  linux            - Build Flutter Linux app (debug)"
	@echo "  linux-debug      - Build Flutter Linux app (debug mode)"
	@echo "  linux-release    - Build Flutter Linux app (release, optimized)"
	@echo ""
	@echo "Run Targets:"
	@echo "  web-run          - Run Flutter web server (development, slow cold start)"
	@echo "  web-serve        - Serve pre-built build/web/ (fast, run 'make web' first)"
	@echo "  linux-run-debug  - Run Flutter Linux app (debug, with hot reload)"
	@echo "  linux-run-profile - Run Flutter Linux app (profile, with DevTools)"
	@echo "  linux-run-release - Run Flutter Linux app (release, optimized)"
	@echo ""
	@echo "Install Targets:"
	@echo "  install          - Build and install extension to remote"
	@echo "  install-local    - Build and install extension to local VS Code"
	@echo "  install-remote   - Build and install extension to remote"
	@echo ""
	@echo "Clean Targets:"
	@echo "  clean            - Clean all build artifacts (except source)"
	@echo "  clean-web        - Clean Flutter web build artifacts"
	@echo "  clean-linux      - Clean Flutter Linux build artifacts"
	@echo "  clean-extension  - Clean extension packaging artifacts"
	@echo "  real-clean       - Deep clean including all generated code"
	@echo ""
	@echo "Development Targets:"
	@echo "  test             - Run Flutter tests"
	@echo "  coverage         - Generate Dart LCOV and HTML coverage reports"
	@echo "  coverage-view    - Serve coverage/html locally on port 8000"
	@echo "  coverity         - Run configured Coverity scan workflow"
	@echo "  sync-version     - Sync pubspec.yaml version → package.json"
	@echo "  force            - Clean everything and rebuild from scratch"
	@echo ""

all: extension

test:
	$(FLUTTER) test $(ARGS)

coverage:
	@bash scripts/generate_coverage.sh

coverage-view:
	@bash scripts/view_coverage.sh

coverage-clean:
	@rm -rf coverage/html coverage/lcov.info

coverity:
	@bash scripts/run_coverity.sh all

coverity-setup:
	@bash scripts/run_coverity.sh setup

coverity-clean:
	@bash scripts/run_coverity.sh clean

package: build
	@echo "Package available at $(SLIM_ZIP)"

verify-elk-distribution:
	@bash scripts/verify_elk_distribution.sh

# ---------------------------------------------------------------------------
# JS asset staging (shared by both run and build paths)
# ---------------------------------------------------------------------------

# Stage Dart-first ELK wrapper to assets/ (Flutter will bundle automatically)
assets/elk_layout_only.js: scripts/stage_js_bridge.sh $(JS_BRIDGE_SOURCES)
	@echo "Staging JS files..."
	@bash scripts/stage_js_bridge.sh

# Legacy target for compatibility
stage-js: assets/elk_layout_only.js

# Validate linux assets (checks that source files exist)
.PHONY: validate-linux-assets
validate-linux-assets: assets/elk_layout_only.js scripts/stage_linux_assets.sh
	@echo "Validating linux assets..."
	@bash scripts/stage_linux_assets.sh

# ---------------------------------------------------------------------------
# BUILD / PACKAGE path  (actual output files track Dart source freshness)
# ---------------------------------------------------------------------------
# These targets use the real build outputs as Make targets.  When any
# $(DART_SOURCES) file is newer than the output, Make triggers a rebuild.
#
# Crucially, `flutter run` (used by the RUN path below) also updates these
# same output files as a side-effect of its own incremental compiler.
# So if you iterate with `flutter run` and then run `make install`,
# Make sees the output is already newer than the sources and skips the
# `flutter build` step — no redundant work.
#
# Flutter web: both debug and release write to build/web/ (Flutter's default).
# We use FLUTTER_WEB_MODE (debug|release) to control the mode; the phony
# targets web-debug / web-release set it and force a rebuild.

FLUTTER_WEB_MODE ?= release
FLUTTER_WEB_BUILD_ARGS ?=
# Release web artifacts use Flutter's WASM entrypoint. The generated
# flutter_bootstrap.js selects the WASM files when they are present, while
# debug builds remain JavaScript-based unless explicitly overridden.
FLUTTER_WEB_WASM ?= $(if $(filter release,$(FLUTTER_WEB_MODE)),1,0)
FLUTTER_WEB_WASM_ARGS := $(if $(filter 1 true yes,$(FLUTTER_WEB_WASM)),--wasm,)

build/web/index.html: web/index.html assets/elk_layout_only.js pubspec.yaml $(DART_SOURCES) \
	scripts/fix_bootstrap.py scripts/verify_flutter_native_dependencies.sh \
	security/native-dependency-exceptions.json
	@echo "Building Flutter web app ($(FLUTTER_WEB_MODE))..."
	# Remove stale JS-only or dual-build output before generating the WASM build.
	@rm -rf build/web
	@$(FLUTTER) pub get && $(FLUTTER) build web --$(FLUTTER_WEB_MODE) $(FLUTTER_WEB_WASM_ARGS) $(FLUTTER_WEB_BUILD_ARGS)
	@echo "Patching flutter_bootstrap.js for webview compatibility..."
	@python3 "$(ROOT)/scripts/fix_bootstrap.py"
	@echo "Staging JS scripts for web root (index.html <script> tags)..."
	@mkdir -p build/web/assets/js
	@cp assets/elk_layout_only.js build/web/assets/
	@cp assets/js/*.js build/web/assets/js/
	@cp assets/js/LICENSE assets/js/README.md build/web/assets/js/
	@cp THIRD_PARTY_NOTICES.md build/web/
	@mkdir -p build/web/licenses
	@cp assets/licenses/elkjs_LICENSES.txt build/web/licenses/
	@bash "$(ROOT)/scripts/verify_flutter_native_dependencies.sh" \
		"$(ROOT)/build/web/canvaskit/canvaskit.wasm"

build/linux/x64/debug/bundle/rohd_schematic_viewer: assets/elk_layout_only.js pubspec.yaml $(DART_SOURCES) \
	scripts/run_flutter_linux.sh scripts/verify_flutter_native_dependencies.sh security/native-dependency-exceptions.json
	@echo "Building Flutter Linux app (debug)..."
	@mkdir -p build/native_assets/linux
	@$(FLUTTER) pub get && bash scripts/run_flutter_linux.sh $(FLUTTER) build linux --debug
	@bash "$(ROOT)/scripts/verify_flutter_native_dependencies.sh" \
		"$(ROOT)/build/linux/x64/debug/bundle/lib/libflutter_linux_gtk.so"

build/linux/x64/release/bundle/rohd_schematic_viewer: assets/elk_layout_only.js pubspec.yaml $(DART_SOURCES) \
	scripts/run_flutter_linux.sh scripts/verify_flutter_native_dependencies.sh security/native-dependency-exceptions.json
	@echo "Building Flutter Linux app (release)..."
	@mkdir -p build/native_assets/linux
	@$(FLUTTER) pub get && bash scripts/run_flutter_linux.sh $(FLUTTER) build linux --release
	@bash "$(ROOT)/scripts/verify_flutter_native_dependencies.sh" \
		"$(ROOT)/build/linux/x64/release/bundle/lib/libflutter_linux_gtk.so"

# Convenience aliases
web: build/web/index.html
linux: build/linux/x64/debug/bundle/rohd_schematic_viewer
linux-debug: build/linux/x64/debug/bundle/rohd_schematic_viewer
linux-release: build/linux/x64/release/bundle/rohd_schematic_viewer

# web-debug / web-release: force the correct mode by cleaning + rebuilding.
# Both land in build/web/ so we must remove the stale output first.
web-debug:
	@rm -f build/web/index.html
	@$(MAKE) build/web/index.html FLUTTER_WEB_MODE=debug

web-release:
	@rm -f build/web/index.html
	@$(MAKE) build/web/index.html FLUTTER_WEB_MODE=release

# ---------------------------------------------------------------------------
# RUN path  (Flutter manages Dart rebuilds; Make only stages assets)
# ---------------------------------------------------------------------------
# These do NOT depend on stamps or $(DART_SOURCES).
# Flutter's incremental compiler + hot reload handle Dart changes.

web-run: assets/elk_layout_only.js
	@echo "Running Flutter web server (development)..."
	@flutter run -d web-server --web-port=9199 --web-hostname=localhost

# Serve the pre-built build/web/ output using a simple HTTP server.
# Much faster than `flutter run` because it skips recompilation.
# Run `make web` or `make web-release` first to produce the build.
web-serve: build/web/index.html
	@echo "Serving pre-built build/web/ on http://localhost:9199"
	@cd build/web && python3 -m http.server 9199 --bind localhost

linux-run-debug: assets/elk_layout_only.js
	@mkdir -p build/native_assets/linux
	@echo "Running Flutter Linux app (debug mode with hot reload)..."
	@bash scripts/run_flutter_linux.sh $(FLUTTER) run -d linux

linux-run-profile: assets/elk_layout_only.js
	@mkdir -p build/native_assets/linux
	@echo "Running Flutter Linux app (profile mode)..."
	@bash scripts/run_flutter_linux.sh $(FLUTTER) run -d linux --profile

linux-run-release: assets/elk_layout_only.js
	@mkdir -p build/native_assets/linux
	@echo "Running Flutter Linux app (release mode)..."
	@bash scripts/run_flutter_linux.sh $(FLUTTER) run -d linux --release

clean: clean-extension clean-web clean-linux
	@echo "Clean complete"

real-clean: clean
	@echo "Running flutter clean..."
	@flutter clean
	@echo "Removing staged assets (only when sources exist)"
	@if [ -f "$(ROOT)/js_bridge/elk_layout_only.js" ]; then \
		rm -f "$(ROOT)/assets/elk_layout_only.js"; \
	else \
		echo "Skipped staged ELK wrapper cleanup: source missing"; \
	fi
	@echo "Real-clean complete"

clean-extension:
	@echo "Cleaning extension build artifacts"
	-rm -rf build/*
	-rm -rf /tmp/vscode_pkg_* || true

clean-flutter-build:
	@echo "Cleaning Flutter build cache and artifacts"
	-rm -rf $(ROOT)/build
	-rm -rf $(ROOT)/.dart_tool

clean-web:
	@echo "Cleaning Flutter web build artifacts"
	-rm -rf $(ROOT)/build/web
	-rm -rf $(ROOT)/build/flutter_assets
	-rm -f $(ROOT)/assets/elk_layout_only.js

clean-linux:
	@echo "Cleaning Flutter Linux build artifacts"
	-rm -rf $(ROOT)/build/linux
	-rm -rf $(ROOT)/build/flutter_assets
	-rm -rf $(ROOT)/linux/flutter/ephemeral
	-rm -f $(ROOT)/linux/flutter/generated_plugin_registrant.cc
	-rm -f $(ROOT)/linux/flutter/generated_plugin_registrant.h
	-rm -f $(ROOT)/linux/flutter/generated_plugins.cmake
	-rm -rf $(ROOT)/linux/shared

# ---------------------------------------------------------------------------
# Extension packaging  (depends on actual build outputs)
# ---------------------------------------------------------------------------
# FLUTTER_WEB_MODE controls debug vs release (default: debug).
#
# Examples:
#   make install                             # debug Flutter web extension
#   make install FLUTTER_WEB_MODE=release     # release Flutter web

# Extension zip (includes Flutter web build)
$(SLIM_ZIP): stage-js build/web/index.html scripts/copy_devtools_extension_assets.cjs | sync-version
	@echo "Running extension build (creates zip)"
	@mkdir -p $(dir $@)
	@OUT="$@" sh scripts/build_extension.sh

# Alias: build target for convenience
build: $(SLIM_ZIP)

# Force rebuild of everything (clean and rebuild)
force: clean extension

# Build VSCode extension
extension: $(SLIM_ZIP)
	@echo "Extension build complete"

# ---------------------------------------------------------------------------
# Install targets
# ---------------------------------------------------------------------------

# Install extension to local VS Code
install-local: extension
	@echo "Installing extension to local VS Code..."
	@code --install-extension "$(SLIM_ZIP)" || echo "Note: VS Code CLI not found; install manually from $(SLIM_ZIP)"

# Install extension to remote VS Code Server
install-remote: extension
	@echo "Installing extension to remote server extensions (~/.vscode-server/extensions)"
	@sh scripts/install_extension_server.sh "$(SLIM_ZIP)"

# Default install target
install: install-remote

# ---------------------------------------------------------------------------
# Version sync  (pubspec.yaml → package.json)
# ---------------------------------------------------------------------------
sync-version:
	@echo "Syncing version $(PUBSPEC_VERSION) from pubspec.yaml → package.json..."
	@if command -v $(NODE) >/dev/null 2>&1; then \
		$(NODE) -e " \
			const fs = require('fs'); \
			const f = '$(ROOT)/package.json'; \
			const pkg = JSON.parse(fs.readFileSync(f,'utf8')); \
			pkg.version = '$(PUBSPEC_VERSION)'; \
			fs.writeFileSync(f, JSON.stringify(pkg, null, 2) + '\n');" ; \
		echo "  package.json → $(PUBSPEC_VERSION)"; \
	else \
		echo "error: Node.js is required to synchronize extension versions."; \
		exit 1; \
	fi
