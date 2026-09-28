#!/bin/bash
# Compila MyFTP en modo release y genera build/MyFTP.app firmada.
#
# Variables opcionales:
#   SIGN_IDENTITY   Identidad de firma, p. ej. "Developer ID Application: Nombre (TEAMID)".
#                   Por defecto "-" (firma ad hoc: sirve para este Mac, no para distribuir).
#   NOTARY_PROFILE  Perfil de notarytool guardado en el Llavero (xcrun notarytool store-credentials).
#                   Si se indica, se notariza y se grapa el ticket a la app.
#   VERSION, BUILD  Versión visible y número de compilación (por defecto 1.0 y 1).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MyFTP"
BUNDLE_ID="com.undoestudio.MyFTP"
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/${APP_NAME}.app"

echo "▸ Compilando (release, Apple silicon)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Creando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Icono: Resources/AppIcon.icon (Icon Composer) o, en su defecto, Resources/AppIcon.icns.
ICON_ENTRY=""
if [[ -d "Resources/AppIcon.icon" ]]; then
    echo "▸ Compilando el icono (Icon Composer)…"
    ICON_TMP="build/icon"
    rm -rf "$ICON_TMP"
    mkdir -p "$ICON_TMP"
    if xcrun actool "Resources/AppIcon.icon" \
        --compile "$ICON_TMP" \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 27.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_TMP/partial.plist" \
        --output-format human-readable-text --errors --warnings > "$ICON_TMP/actool.log" 2>&1; then
        cp "$ICON_TMP"/Assets.car "$APP/Contents/Resources/" 2>/dev/null || true
        cp "$ICON_TMP"/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
        ICON_ENTRY="<key>CFBundleIconName</key><string>AppIcon</string><key>CFBundleIconFile</key><string>AppIcon</string>"
    else
        echo "⚠︎ No se pudo compilar el icono; la app se creará sin él. Detalles:" >&2
        cat "$ICON_TMP/actool.log" >&2
    fi
elif [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Undo Estudio</string>
    ${ICON_ENTRY}
</dict>
</plist>
PLIST

echo "▸ Firmando con identidad: ${SIGN_IDENTITY}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "✗ Para notarizar hace falta un certificado Developer ID (SIGN_IDENTITY)." >&2
        exit 1
    fi
    echo "▸ Notarizando…"
    ditto -c -k --keepParent "$APP" "build/${APP_NAME}.zip"
    xcrun notarytool submit "build/${APP_NAME}.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "▸ Comprimiendo…"
rm -f "build/${APP_NAME}.zip"
ditto -c -k --keepParent "$APP" "build/${APP_NAME}.zip"

echo "✓ Listo: $APP y build/${APP_NAME}.zip"
