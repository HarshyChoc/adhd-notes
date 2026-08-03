#!/bin/bash

set -Eeuo pipefail
trap 'printf "Build failed at line %s.\n" "$LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="StickyNotes"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-MD Sticky Notes}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.mdstickynotes}"
APP_COPYRIGHT="${APP_COPYRIGHT:-Copyright © 2026 MD Sticky Notes}"
APPLE_DEVELOPER_IDENTITY="${APPLE_DEVELOPER_IDENTITY:-}"
APPLE_NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-1}"
CREATE_STYLED_DMG="${CREATE_STYLED_DMG:-0}"
NOTARIZE_DMG="${NOTARIZE_DMG:-1}"
SKIP_DMG="${SKIP_DMG:-0}"
SKIP_ZIP="${SKIP_ZIP:-0}"

default_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Sources/StickyNotes/Info.plist" 2>/dev/null \
    || printf "1.2.0"
}

default_build_number() {
  git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf "1"
}

APP_VERSION="${APP_VERSION:-$(default_version)}"
APP_BUILD="${APP_BUILD:-$(default_build_number)}"

APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_TEMPLATE="$ROOT_DIR/Sources/StickyNotes/Info.plist"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
ZIP_PATH="$ROOT_DIR/build/MDStickyNotes.zip"
DMG_PATH="$ROOT_DIR/build/MDStickyNotes.dmg"

log() {
  printf "%s\n" "$1"
}

build_web_editor() {
  log "Building web editor..."
  cd "$ROOT_DIR/editor-web"
  npm run build
  cp dist/editor.bundle.js "$ROOT_DIR/Sources/StickyNotes/Resources/Editor/editor.bundle.js"
  log "Web editor built."
}

build_swift_binary() {
  log "Building Swift release binary..."
  cd "$ROOT_DIR"
  swift build -c release
  log "Swift binary built."
}

prepare_bundle() {
  log "Assembling app bundle..."
  rm -rf "$ROOT_DIR/build"
  mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

  cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
  cp -R "$ROOT_DIR/Sources/StickyNotes/Resources/." "$RESOURCES_DIR/"
  cp "$INFO_PLIST_TEMPLATE" "$INFO_PLIST"
  printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

  plutil -replace CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
  plutil -replace CFBundleIdentifier -string "$PRODUCT_BUNDLE_IDENTIFIER" "$INFO_PLIST"
  plutil -replace CFBundleName -string "$APP_DISPLAY_NAME" "$INFO_PLIST"
  plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$INFO_PLIST"
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$INFO_PLIST"
  plutil -replace CFBundleVersion -string "$APP_BUILD" "$INFO_PLIST"
  plutil -replace NSHumanReadableCopyright -string "$APP_COPYRIGHT" "$INFO_PLIST"

  [[ "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" == "$APP_VERSION" ]]
  [[ "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" == "$APP_BUILD" ]]

  log "App bundle assembled at $APP_DIR"
}

sign_app() {
  log "Signing app bundle..."
  if [[ -n "$APPLE_DEVELOPER_IDENTITY" ]]; then
    codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp \
      --sign "$APPLE_DEVELOPER_IDENTITY" \
      "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    codesign -d --verbose=2 "$APP_DIR" 2>&1 | grep -F "Authority=$APPLE_DEVELOPER_IDENTITY"
    log "App signed with Developer ID identity."
    return
  fi

  if [[ "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    printf "APPLE_DEVELOPER_IDENTITY is required when ALLOW_ADHOC_SIGNING=0.\n" >&2
    exit 1
  fi

  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  log "App signed ad-hoc for local development."
}

create_zip() {
  [[ "$SKIP_ZIP" == "1" ]] && return
  log "Creating ZIP artifact..."
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  log "ZIP created at $ZIP_PATH"
}

styled_dmg() {
  local tmp_dmg="$ROOT_DIR/build/tmp.dmg"
  local dmg_dir="$ROOT_DIR/build/dmg"
  local vol_name="MD Sticky Notes"
  local mount_dir="/Volumes/$vol_name"

  rm -rf "$dmg_dir" "$tmp_dmg" "$DMG_PATH"
  mkdir -p "$dmg_dir"
  cp -R "$APP_DIR" "$dmg_dir/"
  ln -s /Applications "$dmg_dir/Applications"

  hdiutil create -volname "$vol_name" -srcfolder "$dmg_dir" -ov -format UDRW "$tmp_dmg"
  hdiutil attach "$tmp_dmg" -readwrite -noverify -noautoopen
  sleep 2

  osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$vol_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 400, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 80}
        set position of item "Applications" of container window to {150, 260}
        close
        open
    end tell
end tell
APPLESCRIPT

  sleep 1
  hdiutil detach "$mount_dir"
  hdiutil convert "$tmp_dmg" -format UDZO -o "$DMG_PATH"
  rm -f "$tmp_dmg"
  rm -rf "$dmg_dir"
}

plain_dmg() {
  local dmg_dir="$ROOT_DIR/build/dmg"
  local vol_name="MD Sticky Notes"

  rm -rf "$dmg_dir" "$DMG_PATH"
  mkdir -p "$dmg_dir"
  cp -R "$APP_DIR" "$dmg_dir/"
  ln -s /Applications "$dmg_dir/Applications"
  hdiutil create -volname "$vol_name" -srcfolder "$dmg_dir" -ov -format UDZO "$DMG_PATH"
  rm -rf "$dmg_dir"
}

create_dmg() {
  [[ "$SKIP_DMG" == "1" ]] && return
  log "Creating DMG artifact..."

  if [[ "$CREATE_STYLED_DMG" == "1" && -z "${CI:-}" ]]; then
    styled_dmg
  else
    plain_dmg
  fi

  if [[ -n "$APPLE_DEVELOPER_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$APPLE_DEVELOPER_IDENTITY" "$DMG_PATH"
  fi

  log "DMG created at $DMG_PATH"
}

submit_notarization() {
  local target_path="$1"
  log "Submitting $target_path for notarization..."
  xcrun notarytool submit "$target_path" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  log "Notarization accepted for $target_path"
}

notarize_app_bundle() {
  if [[ -z "$APPLE_DEVELOPER_IDENTITY" || -z "$APPLE_NOTARY_PROFILE" ]]; then
    return
  fi

  local notarize_zip="$ROOT_DIR/build/MDStickyNotes-notary.zip"
  rm -f "$notarize_zip"
  ditto -c -k --keepParent "$APP_DIR" "$notarize_zip"
  submit_notarization "$notarize_zip"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  rm -f "$notarize_zip"
}

notarize_dmg_artifact() {
  if [[ -z "$APPLE_DEVELOPER_IDENTITY" || -z "$APPLE_NOTARY_PROFILE" ]]; then
    return
  fi
  if [[ "$SKIP_DMG" != "1" && "$NOTARIZE_DMG" == "1" ]]; then
    submit_notarization "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
  fi
}

main() {
  log "Building $APP_DISPLAY_NAME $APP_VERSION ($APP_BUILD)..."
  build_web_editor
  build_swift_binary
  prepare_bundle
  sign_app
  notarize_app_bundle
  create_zip
  create_dmg
  notarize_dmg_artifact

  log "Build complete."
  log "App: $APP_DIR"
  if [[ "$SKIP_ZIP" != "1" ]]; then
    log "ZIP: $ZIP_PATH"
  fi
  if [[ "$SKIP_DMG" != "1" ]]; then
    log "DMG: $DMG_PATH"
  fi
}

main "$@"
