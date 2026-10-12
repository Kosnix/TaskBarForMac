#!/usr/bin/env bash
# Builds the Swift package and assembles it into a real TaskBarForMac.app
# bundle (Info.plist, bundled themes, code signature), since `swift build`
# alone only produces a bare executable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IDENTITY="TaskBarForMac Local Dev"
DO_INSTALL=false
CONFIGURATION="release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        --install)
            DO_INSTALL=true
            shift
            ;;
        --debug)
            CONFIGURATION="debug"
            shift
            ;;
        *)
            echo "Argument inconnu: $1" >&2
            exit 1
            ;;
    esac
done

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

APP_NAME="TaskBarForMac.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"

echo "==> Assemblage de $APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/$CONFIGURATION/TaskBarForMac" "$APP_DIR/Contents/MacOS/TaskBarForMac"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/Sources/Resources/Themes" "$APP_DIR/Contents/Resources/Themes"
for lang in fr en es ru; do
    cp -R "$ROOT_DIR/Sources/Resources/$lang.lproj" "$APP_DIR/Contents/Resources/$lang.lproj"
done

echo "==> Signature avec l'identité: $IDENTITY"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP_DIR"
else
    echo "Identité '$IDENTITY' introuvable — signature ad-hoc (la permission Accessibilité sera à redonner à chaque build)."
    echo "Lancez d'abord: Scripts/setup-signing-identity.sh"
    codesign --force --deep --sign - "$APP_DIR"
fi

if [[ "$DO_INSTALL" == true ]]; then
    echo "==> Installation dans /Applications"
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/$APP_NAME"
    echo "Installé: /Applications/$APP_NAME"
else
    echo "Build prêt: $APP_DIR"
    echo "Lancer avec: open \"$APP_DIR\""
fi
