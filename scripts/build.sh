#!/bin/bash
# Build Coding Island for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Apple Developer Team ID (used for Developer ID signing).
# If you have multiple teams, override via CODING_ISLAND_TEAM_ID.
TEAM_ID_DEFAULT="4U87V5XYY4"
TEAM_ID="${CODING_ISLAND_TEAM_ID:-$TEAM_ID_DEFAULT}"

UNSIGNED_BUILD="${CODING_ISLAND_UNSIGNED:-}"
if [[ "$UNSIGNED_BUILD" == "1" || "$UNSIGNED_BUILD" == "true" ]]; then
    echo "Unsigned build mode enabled (CODING_ISLAND_UNSIGNED=1)"
    ENABLE_HARDENED_RUNTIME="NO"
    # Work around occasional Swift compiler crashes in Release+WMO builds by
    # forcing incremental compilation and disabling optimizations.
    SWIFT_BUILD_ARGS=(
        SWIFT_COMPILATION_MODE=incremental
        SWIFT_WHOLE_MODULE_OPTIMIZATION=NO
        SWIFT_OPTIMIZATION_LEVEL=-Onone
    )
    SIGNING_ARGS=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGN_IDENTITY=
    )
else
    ENABLE_HARDENED_RUNTIME="YES"
    SWIFT_BUILD_ARGS=()
    SIGNING_ARGS=()

    # Prefer Developer ID signing when available (required for notarization).
    # If the Developer ID identity is not installed, fall back to the project's
    # default automatic signing (typically Apple Development).
    HAS_DEVELOPER_ID=0
    set +e
    security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" 
    if [ $? -eq 0 ]; then
        HAS_DEVELOPER_ID=1
    fi
    set -e

    if [ "$HAS_DEVELOPER_ID" -eq 1 ]; then
        # Manual signing avoids Xcode/SwiftPM "automatic signing for development"
        # conflicts when overriding the identity from the command line.
        SIGNING_ARGS=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY="Developer ID Application"
            DEVELOPMENT_TEAM="$TEAM_ID"
            OTHER_CODE_SIGN_FLAGS="--timestamp"
            PROVISIONING_PROFILE_SPECIFIER=
            PROVISIONING_PROFILE=
        )
    else
        SIGNING_ARGS=(
            CODE_SIGN_STYLE=Automatic
        )
    fi
fi

echo "=== Building Coding Island ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive — pipe to xcpretty when available, but capture the real
# xcodebuild exit code so a noisy-but-successful xcpretty doesn't fail the build.
echo "Archiving..."

ARCHIVE_LOG="$BUILD_DIR/archive.log"
ARCHIVE_FALLBACK_LOG="$BUILD_DIR/archive-fallback.log"

run_archive() {
    local log_path="$1"
    shift

    set +e
    if command -v xcpretty >/dev/null 2>&1; then
        xcodebuild archive \
            -scheme ClaudeIsland \
            -configuration Release \
            -archivePath "$ARCHIVE_PATH" \
            -destination "generic/platform=macOS" \
            -allowProvisioningUpdates \
            ENABLE_HARDENED_RUNTIME="$ENABLE_HARDENED_RUNTIME" \
            "${SIGNING_ARGS[@]}" \
            "${SWIFT_BUILD_ARGS[@]}" \
            "$@" \
            2>&1 | tee "$log_path" | xcpretty
        local exit_code=${PIPESTATUS[0]}
        set -e
        return "$exit_code"
    fi

    echo "xcpretty not found; running xcodebuild with full output"
    xcodebuild archive \
        -scheme ClaudeIsland \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        -allowProvisioningUpdates \
        ENABLE_HARDENED_RUNTIME="$ENABLE_HARDENED_RUNTIME" \
        "${SIGNING_ARGS[@]}" \
        "${SWIFT_BUILD_ARGS[@]}" \
        "$@" \
        2>&1 | tee "$log_path"
    local exit_code=${PIPESTATUS[0]}
    set -e
    return "$exit_code"
}

if ! run_archive "$ARCHIVE_LOG"; then
    echo "ERROR: Archive failed. See log: $ARCHIVE_LOG"

    if [[ "$UNSIGNED_BUILD" == "1" || "$UNSIGNED_BUILD" == "true" ]]; then
        exit 1
    fi

    # Work around occasional Swift compiler crashes in Release+WMO builds.
    # Keep Release optimization (-O) but disable whole-module optimization.
    FALLBACK_SWIFT_ARGS=(
        SWIFT_COMPILATION_MODE=incremental
        SWIFT_WHOLE_MODULE_OPTIMIZATION=NO
        SWIFT_OPTIMIZATION_LEVEL=-O
    )

    echo "Retrying archive with WMO disabled (Swift compiler crash workaround)..."
    if ! run_archive "$ARCHIVE_FALLBACK_LOG" "${FALLBACK_SWIFT_ARGS[@]}"; then
        echo "Archive still failing with -O. Trying again with optimizations disabled (-Onone)..."

        ARCHIVE_FALLBACK2_LOG="$BUILD_DIR/archive-fallback-onone.log"
        FALLBACK2_SWIFT_ARGS=(
            SWIFT_COMPILATION_MODE=incremental
            SWIFT_WHOLE_MODULE_OPTIMIZATION=NO
            SWIFT_OPTIMIZATION_LEVEL=-Onone
        )

        if ! run_archive "$ARCHIVE_FALLBACK2_LOG" "${FALLBACK2_SWIFT_ARGS[@]}"; then
            echo "ERROR: Archive failed again. See log: $ARCHIVE_FALLBACK2_LOG"
            exit 1
        fi
    fi
fi

if [[ "$UNSIGNED_BUILD" == "1" || "$UNSIGNED_BUILD" == "true" ]]; then
    echo ""
    echo "Exporting (unsigned): copying .app from archive"
    mkdir -p "$EXPORT_PATH"
    rm -rf "$EXPORT_PATH/Coding Island.app"
    cp -R "$ARCHIVE_PATH/Products/Applications/Coding Island.app" "$EXPORT_PATH/"

    echo ""
    echo "=== Build Complete ==="
    echo "App exported to: $EXPORT_PATH/Coding Island.app"
    echo ""
    echo "NOTE: This build is unsigned. It cannot be notarized or distributed via Gatekeeper without a Developer ID certificate."
    exit 0
fi

# Developer ID export requires a Developer ID Application identity in the keychain.
HAS_DEVELOPER_ID_EXPORT=0
set +e
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"
if [ $? -eq 0 ]; then
    HAS_DEVELOPER_ID_EXPORT=1
fi
set -e

if [ "$HAS_DEVELOPER_ID_EXPORT" -ne 1 ]; then
    echo ""
    echo "Exporting: Developer ID Application identity not found; copying .app from archive"
    mkdir -p "$EXPORT_PATH"
    rm -rf "$EXPORT_PATH/Coding Island.app"
    cp -R "$ARCHIVE_PATH/Products/Applications/Coding Island.app" "$EXPORT_PATH/"

    echo ""
    echo "=== Build Complete ==="
    echo "App exported to: $EXPORT_PATH/Coding Island.app"
    echo ""
    echo "NOTE: This app is not signed with a Developer ID Application certificate. It cannot be notarized for Gatekeeper distribution."
    exit 0
fi

# Create ExportOptions.plist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
set +e
if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        2>&1 | xcpretty
    EXPORT_EXIT=${PIPESTATUS[0]}
else
    echo "xcpretty not found; running xcodebuild with full output"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    EXPORT_EXIT=$?
fi
set -e

if [ "$EXPORT_EXIT" -ne 0 ]; then
    echo "ERROR: Export failed. Re-running with full output..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Coding Island.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
