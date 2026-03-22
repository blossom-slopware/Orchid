#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build_release.sh
# Builds a release .zip of Orchid.app with the glm-ocr-server binary bundled.
#
# Usage:
#   ./scripts/build_release.sh [VERSION]
#
# If VERSION is not provided it defaults to the value in VERSION file or 0.0.0.
# Produces: build/Orchid-<VERSION>.zip
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    if [[ -f "$REPO_ROOT/VERSION" ]]; then
        VERSION="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
    else
        VERSION="0.0.0"
    fi
fi

echo "==> Building Orchid $VERSION"

# ---------------------------------------------------------------------------
# 1. Build glm-ocr-server (Rust, release)
# ---------------------------------------------------------------------------
CARGO_MANIFEST="$REPO_ROOT/ocr-inference/glm-ocr-rs/Cargo.toml"
echo "--> cargo build --release"
cargo build --release --manifest-path "$CARGO_MANIFEST"

RUST_BINARY="$REPO_ROOT/ocr-inference/glm-ocr-rs/target/release/glm-ocr-server"
if [[ ! -f "$RUST_BINARY" ]]; then
    echo "ERROR: Rust binary not found at $RUST_BINARY"
    exit 1
fi
echo "    Binary: $RUST_BINARY ($(du -sh "$RUST_BINARY" | cut -f1))"

# ---------------------------------------------------------------------------
# 2. Build Orchid.app (Xcode, Release)
# ---------------------------------------------------------------------------
BUILD_DIR="$REPO_ROOT/build"
APP_BUILD_DIR="$BUILD_DIR/Release"
mkdir -p "$BUILD_DIR"

echo "--> xcodebuild"
xcodebuild \
    -project "$REPO_ROOT/Orchid.xcodeproj" \
    -scheme Orchid \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    CONFIGURATION_BUILD_DIR="$APP_BUILD_DIR" \
    build

APP_PATH="$APP_BUILD_DIR/Orchid.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Orchid.app not found at $APP_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Embed glm-ocr-server into the app bundle
# ---------------------------------------------------------------------------
BIN_DIR="$APP_PATH/Contents/Resources/bin"
echo "--> Embedding glm-ocr-server into bundle"
mkdir -p "$BIN_DIR"
cp "$RUST_BINARY" "$BIN_DIR/glm-ocr-server"
chmod +x "$BIN_DIR/glm-ocr-server"

# ---------------------------------------------------------------------------
# 4. Ad-hoc code sign (no Apple Developer account required)
# ---------------------------------------------------------------------------
echo "--> Signing (ad-hoc)"
codesign --deep --force --sign "-" "$APP_PATH"

# ---------------------------------------------------------------------------
# 5. Package into .zip
# ---------------------------------------------------------------------------
ZIP_NAME="Orchid-${VERSION}.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
echo "--> Creating $ZIP_NAME"
(cd "$APP_BUILD_DIR" && zip -qr "$ZIP_PATH" Orchid.app)

echo "--> SHA256"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "    $SHA256  $ZIP_NAME"

# Write sha256 to a sidecar file for easy copy-paste into the Cask
echo "$SHA256" > "$ZIP_PATH.sha256"

echo ""
echo "Done: $ZIP_PATH"
echo "Size: $(du -sh "$ZIP_PATH" | cut -f1)"
echo "SHA256: $SHA256"
echo ""
echo "Next steps:"
echo "  1. Create a GitHub Release tagged v${VERSION}"
echo "  2. Upload $ZIP_NAME to the release"
echo "  3. Update homebrew-orchid/Casks/orchid.rb:"
echo "       version \"${VERSION}\""
echo "       sha256 \"${SHA256}\""
