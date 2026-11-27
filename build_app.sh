#!/bin/bash
# Build Slit.app from the SwiftPM target.
#   --install    also copy to /Applications
#   --dmg        also produce a styled DMG in dist/
#   --notarize   submit to Apple and staple the result (implies --dmg).
#                Requires a Developer ID Application certificate and stored
#                notary credentials — see NOTARY_PROFILE below.
#
# To ship a browser-downloadable build:  ./build_app.sh --notarize
set -e

cd "$(dirname "$0")"

APP_NAME="Slit"
APP_BUNDLE="$APP_NAME.app"
BIN_NAME="TextReaderHelper"               # produced by SwiftPM target
BUNDLE_ID="com.alfonsomulet.slit"
DISPLAY_NAME="Slit"
VOLUME_NAME="Slit"

# Notary credential profile, created once with:
#   xcrun notarytool store-credentials "slit-notary" \
#       --apple-id "you@example.com" --team-id TEAMID --password APP-SPECIFIC-PW
NOTARY_PROFILE="${NOTARY_PROFILE:-slit-notary}"

DIST_DIR="dist"

# Version shown to users, and the build number Sparkle compares to decide
# whether an update is newer. The release workflow sets both from the tag and
# the commit count; local builds default to 1.0 (1).
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Updates: the feed Slit reads and the public half of the EdDSA key every
# update must be signed with (the private half is in the maintainer's keychain
# and the SPARKLE_ED_PRIVATE_KEY repository secret).
FEED_URL="https://raw.githubusercontent.com/Ryukun1/slit/main/appcast.xml"
SPARKLE_PUBLIC_KEY="DOR7SRSzTrCnOF5ksh+5sgSN+8yCxVfhGepO4tmR3r0="

INSTALL=false
DMG=false
NOTARIZE=false
for arg in "$@"; do
    [ "$arg" = "--install" ] && INSTALL=true
    [ "$arg" = "--dmg" ] && DMG=true
    [ "$arg" = "--notarize" ] && { NOTARIZE=true; DMG=true; }
done

# Pick a signing identity, best first:
#
#   1. "Developer ID Application" — the ONLY kind Gatekeeper accepts on another
#      person's Mac. Required for notarization, and therefore for any build
#      that gets downloaded from a browser.
#   2. "Apple Development" — machine-local only. Fine for your own testing:
#      its designated requirement is keyed to the Team ID, so macOS keeps the
#      Accessibility / Screen Recording grant across every rebuild. But a
#      download signed with this is REJECTED by Gatekeeper ("Slit is damaged"),
#      with no right-click→Open escape hatch.
#   3. ad-hoc — grant survives only while the binary's hash is unchanged.
#
# Override with: SIGN_IDENTITY="..."
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "$1" | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]+).*/\1/'
}

SIGN_IS_DEVELOPER_ID=false
if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Caller supplied one; trust it, but detect whether it can be notarized.
    if security find-certificate -c "$SIGN_IDENTITY" 2>/dev/null | grep -q "Developer ID Application" \
       || [ "${SIGN_IDENTITY_IS_DEVELOPER_ID:-false}" = true ]; then
        SIGN_IS_DEVELOPER_ID=true
    fi
    echo "Using signing identity (from environment): $SIGN_IDENTITY"
else
    SIGN_IDENTITY=$(find_identity "Developer ID Application")
    if [ -n "$SIGN_IDENTITY" ]; then
        SIGN_IS_DEVELOPER_ID=true
        echo "Using signing identity: $SIGN_IDENTITY (Developer ID — distributable)"
    else
        SIGN_IDENTITY=$(find_identity "Apple Development")
        if [ -n "$SIGN_IDENTITY" ]; then
            echo "Using signing identity: $SIGN_IDENTITY (Apple Development — local only)"
        else
            SIGN_IDENTITY="-"
            echo "No signing identity found — falling back to ad-hoc signing."
        fi
    fi
fi

# Fail fast on an impossible notarization request, before spending a build and
# a DMG package on it. Apple rejects anything not signed with Developer ID.
if [ "$NOTARIZE" = true ]; then
    if [ "$SIGN_IS_DEVELOPER_ID" != true ]; then
        echo ""
        echo "❌ --notarize needs a 'Developer ID Application' certificate."
        echo "   Current identity: $SIGN_IDENTITY"
        echo ""
        echo "   An 'Apple Development' cert only works on your own machines."
        echo "   A DMG signed with it is rejected by Gatekeeper on download."
        echo ""
        echo "   Fix: enroll at developer.apple.com (\$99/yr), then in Xcode →"
        echo "   Settings → Accounts → Manage Certificates → + → Developer ID"
        echo "   Application."
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo ""
        echo "❌ No notary credentials found for profile '$NOTARY_PROFILE'."
        echo ""
        echo "   Create them once (needs an app-specific password from"
        echo "   appleid.apple.com → Sign-In and Security → App-Specific Passwords):"
        echo ""
        echo "   xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "       --apple-id \"you@example.com\" \\"
        echo "       --team-id TEAMID \\"
        echo "       --password APP-SPECIFIC-PASSWORD"
        exit 1
    fi
fi

# SwiftUI's @State is a macro on recent SDKs, and its plugin
# (libSwiftUIMacros.dylib) ships only with a full Xcode — CommandLineTools
# alone cannot compile this target. Prefer a full Xcode when one is present.
if [ -z "$DEVELOPER_DIR" ] && \
   ! ls "$(xcode-select -p)"/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib >/dev/null 2>&1; then
    for CANDIDATE in \
        /Applications/Xcode.app \
        /Applications/Xcode-beta.app \
        "$HOME/Downloads/Xcode-beta.app"
    do
        if [ -f "$CANDIDATE/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
            export DEVELOPER_DIR="$CANDIDATE/Contents/Developer"
            echo "Using toolchain: $CANDIDATE"
            break
        fi
    done
fi

echo "Building release binary..."
swift build -c release

BIN_PATH=".build/release/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "Build failed — binary not found at $BIN_PATH"
    exit 1
fi

# SwiftPM puts target resources in TextReaderHelper_TextReaderHelper.bundle
RESOURCE_BUNDLE=".build/release/TextReaderHelper_TextReaderHelper.bundle"

echo "Assembling $APP_BUNDLE..."
# Build the bundle IN PLACE (no rm -rf of the whole bundle). macOS keys
# Accessibility / Input Monitoring grants on the app's code-signature hash
# (cdhash) + path. If we wipe and re-sign on every run, the cdhash changes and
# the grant is lost. So we only overwrite the binary when it actually changed,
# and only re-sign when the binary changed — keeping the cdhash stable across
# no-op rebuilds.
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

DEST_BIN="$APP_BUNDLE/Contents/MacOS/$BIN_NAME"
BIN_CHANGED=false
if [ ! -f "$DEST_BIN" ] || ! cmp -s "$BIN_PATH" "$DEST_BIN"; then
    cp "$BIN_PATH" "$DEST_BIN"
    BIN_CHANGED=true
    echo "  binary updated"
else
    echo "  binary unchanged — keeping existing signature"
fi

if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# --- Sparkle (the updater) ---------------------------------------------------
# Embedded in Contents/Frameworks (the binary's rpath points there) and signed
# inside-out with the same identity as the app. Copied and signed again only
# when SwiftPM's copy is a different version, so an unchanged rebuild keeps
# the app's signature (and with it the Accessibility grant).
SPARKLE_SRC="$(swift build -c release --show-bin-path)/Sparkle.framework"
SPARKLE_DEST="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
FRAMEWORK_CHANGED=false
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "❌ Sparkle.framework not found at $SPARKLE_SRC"
    exit 1
fi
sparkle_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Resources/Info.plist" 2>/dev/null || true
}
if [ ! -d "$SPARKLE_DEST" ] \
   || [ "$(sparkle_version "$SPARKLE_SRC")" != "$(sparkle_version "$SPARKLE_DEST")" ] \
   || ! codesign --verify --strict "$SPARKLE_DEST" >/dev/null 2>&1; then
    echo "  embedding Sparkle $(sparkle_version "$SPARKLE_SRC")"
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    rm -rf "$SPARKLE_DEST"
    # ditto keeps the framework's symlinks intact; cp -R can flatten them.
    ditto "$SPARKLE_SRC" "$SPARKLE_DEST"
    FRAMEWORK_CHANGED=true
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>SUFeedURL</key>
    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Slit needs accessibility access to detect text on screen and respond to keyboard shortcuts.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Slit reads the text you point at by capturing that part of your screen. Nothing is recorded, stored, or sent anywhere.</string>
</dict>
</plist>
EOF

# Decide whether to (re)sign.
#  - Real cert: its designated requirement is keyed to the Team ID, which is
#    stable across rebuilds, so signing every changed build is safe and the
#    Accessibility grant persists. (No point re-signing an unchanged binary.)
#  - Ad-hoc ("-"): the grant is keyed to the binary's cdhash, so re-signing an
#    unchanged binary would needlessly mint a new hash and drop the grant.
#    Only sign when the binary changed or the bundle isn't validly signed yet.
NEEDS_SIGN=false
if [ "$BIN_CHANGED" = true ] || [ "$FRAMEWORK_CHANGED" = true ]; then
    NEEDS_SIGN=true
elif ! codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    NEEDS_SIGN=true
fi

# Signs Sparkle's nested helpers, then the framework, then the app itself.
# No --deep on the app: it would stamp Slit's bundle id onto Sparkle's parts.
sign_bundle() {
    local bundle="$1"
    local fw="$bundle/Contents/Frameworks/Sparkle.framework"
    local part
    for part in \
        "$fw/Versions/B/XPCServices/Installer.xpc" \
        "$fw/Versions/B/XPCServices/Downloader.xpc" \
        "$fw/Versions/B/Autoupdate" \
        "$fw/Versions/B/Updater.app" \
        "$fw"
    do
        [ -e "$part" ] || continue
        codesign --force --sign "$SIGN_IDENTITY" --options runtime \
            --preserve-metadata=entitlements "$part" 2>&1 \
            | grep -v "replacing existing signature" || true
    done
    codesign --force \
        --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --options runtime \
        "$bundle" 2>&1 | grep -v "replacing existing signature" || true
    codesign --verify --deep --strict "$bundle"
}

if [ "$NEEDS_SIGN" = true ]; then
    echo "Signing ($SIGN_IDENTITY)..."
    sign_bundle "$APP_BUNDLE"
else
    echo "Signature unchanged — Accessibility/Input Monitoring grant preserved."
fi

# --- Notarize the app -------------------------------------------------------
# Done BEFORE packaging so the copy inside the DMG carries its own stapled
# ticket. That matters: a user who drags the app out and deletes the DMG still
# has a bundle that validates offline. The DMG gets its own ticket further down.
if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "Notarizing $APP_BUNDLE (this can take a few minutes)..."

    NOTARY_ZIP="$DIST_DIR/$APP_NAME-notary.zip"
    mkdir -p "$(dirname "$NOTARY_ZIP")"
    rm -f "$NOTARY_ZIP"

    # ditto --keepParent preserves the .app wrapper; plain `zip` mangles
    # symlinks and framework structure and Apple rejects the result.
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"

    if ! xcrun notarytool submit "$NOTARY_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait; then
        echo ""
        echo "❌ Notarization failed. Fetch the details with:"
        echo "   xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
        echo "   xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
        rm -f "$NOTARY_ZIP"
        exit 1
    fi
    rm -f "$NOTARY_ZIP"

    # Staple the ticket into the bundle so Gatekeeper validates without network.
    echo "Stapling ticket to $APP_BUNDLE..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    echo "✅ App notarized and stapled"
fi

if [ "$INSTALL" = true ]; then
    INSTALLED="/Applications/$APP_BUNDLE"
    # Sync IN PLACE rather than rm -rf + cp. Deleting the bundle gives the new
    # copy a fresh identity that TCC sees as a different app; rsync over the
    # existing bundle keeps the same path/inode so the (cert-based) grant holds.
    echo "Installing to /Applications (in place)..."
    mkdir -p "$INSTALLED"
    rsync -a --delete "$APP_BUNDLE/" "$INSTALLED/"

    # Re-sign the installed copy so its designated requirement is the stable
    # certificate-based one (not a stale cdhash from a previous ad-hoc build).
    sign_bundle "$INSTALLED"

    echo "✅ Installed to $INSTALLED"
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "⚠️  Ad-hoc signed — grant won't survive code changes. Get an Apple"
        echo "    Development cert (free in Xcode) for permanent persistence."
    else
        echo "🔒 Cert-signed (Team $SIGN_IDENTITY) — grant Accessibility ONCE and"
        echo "    every future rebuild keeps it (same path + stable signature)."
    fi
else
    echo "✅ Built $APP_BUNDLE"
    echo ""
    echo "💡 Run from /Applications so the Accessibility grant persists:"
    echo "   ./build_app.sh --install"
fi

# --- DMG packaging ---------------------------------------------------------
if [ "$DMG" = true ]; then
    echo ""
    echo "Packaging DMG..."

    STAGE_DIR="$DIST_DIR/dmg-stage"
    DMG_NAME="slit.dmg"
    DMG_PATH="$DIST_DIR/$DMG_NAME"
    BG_PATH="Resources/dmg-background.png"
    BG_PATH_2X="Resources/dmg-background@2x.png"

    rm -rf "$STAGE_DIR" "$DMG_PATH"
    mkdir -p "$STAGE_DIR/.background"

    # Copy the app and create an /Applications shortcut for drag-install
    cp -R "$APP_BUNDLE" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"

    # Copy background image into the hidden .background folder
    if [ -f "$BG_PATH" ]; then
        cp "$BG_PATH" "$STAGE_DIR/.background/background.png"
    fi
    if [ -f "$BG_PATH_2X" ]; then
        cp "$BG_PATH_2X" "$STAGE_DIR/.background/background@2x.png"
    fi

    # Make a temporary read/write DMG so we can configure the Finder window
    TMP_DMG="$DIST_DIR/.tmp-$DMG_NAME"
    rm -f "$TMP_DMG"
    hdiutil create \
        -volname "$VOLUME_NAME" \
        -srcfolder "$STAGE_DIR" \
        -ov -format UDRW \
        -fs HFS+ \
        "$TMP_DMG" >/dev/null

    # Mount and apply Finder layout via AppleScript
    MOUNT_POINT=$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen | \
        awk '/\/Volumes\// {for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | \
        sed 's/ *$//')

    if [ -z "$MOUNT_POINT" ]; then
        echo "❌ Failed to mount DMG"
        exit 1
    fi

    echo "Configuring Finder window layout..."

    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.png"
        -- Position icons (matches the painted arrow in the background)
        set position of item "$APP_BUNDLE" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        update without registering applications
        delay 0.5
        close
    end tell
end tell
APPLESCRIPT

    # Wait for Finder to flush .DS_Store
    sync
    sleep 1

    hdiutil detach "$MOUNT_POINT" >/dev/null

    # Convert to compressed read-only DMG for distribution
    hdiutil convert "$TMP_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$DMG_PATH" >/dev/null
    rm -f "$TMP_DMG"

    rm -rf "$STAGE_DIR"

    # The DMG is a separate distributable object from the app inside it, so it
    # needs its own signature and its own notarization ticket. Without this the
    # user hits a warning on mounting, even though the app within is notarized.
    if [ "$NOTARIZE" = true ]; then
        echo "Signing DMG..."
        codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

        echo "Notarizing DMG (this can take a few minutes)..."
        if ! xcrun notarytool submit "$DMG_PATH" \
                --keychain-profile "$NOTARY_PROFILE" \
                --wait; then
            echo ""
            echo "❌ DMG notarization failed. Details:"
            echo "   xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
            exit 1
        fi

        echo "Stapling ticket to DMG..."
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH"

        echo ""
        echo "✅ DMG notarized and stapled: $DMG_PATH"
        echo "   Verify it the way a downloader sees it:"
        echo "     spctl -a -vvv -t open --context context:primary-signature \"$DMG_PATH\""
        echo "   Expect: accepted / source=Notarized Developer ID"
    else
        echo "✅ DMG ready: $DMG_PATH"
        if [ "$SIGN_IS_DEVELOPER_ID" = true ]; then
            echo "⚠️  NOT notarized. Gatekeeper will still block this on download."
            echo "    Run with --notarize to produce a shippable DMG."
        else
            echo "⚠️  NOT distributable — signed with '$SIGN_IDENTITY'."
            echo "    Downloaders get \"Slit is damaged and can't be opened\"."
            echo "    Local testing only. See --notarize for the shippable path."
        fi
    fi
fi
