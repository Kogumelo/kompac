#!/bin/zsh
# Builds Kompac and assembles the .app bundle (ad-hoc signature, for local use).
# --install: also replaces /Applications/Kompac.app, the copy Finder's "Open With" uses.
set -e
cd "$(dirname "$0")"

install=false
case "$1" in
    "") ;;
    --install) install=true ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

# Every NSLocalizedString key in the source must be translated in every language.
keys=$(grep -ho 'NSLocalizedString("[^"]*"' Sources/**/*.swift | cut -d'"' -f2 | sort -u)
for strings in Resources/*.lproj/Localizable.strings; do
    plutil -lint -s "$strings"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        grep -qF "\"$key\" =" "$strings" || { echo "Missing \"$key\" in $strings" >&2; exit 1; }
    done <<< "$keys"
done

swift build -c release --product Kompac
BIN="$(swift build -c release --show-bin-path)/Kompac"

APP=Kompac.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# build number = commit count; KompacCommit = short hash (+ "-dirty" when tracked files differ from it),
# shown in About Kompac
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" \
    -c "Add :KompacCommit string $commit" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Kompac"
# app icon: generated from icon/kompac.svg by icon/make-icon.sh
cp icon/Kompac.icns "$APP/Contents/Resources/Kompac.icns"
# engine: the official 7-Zip 7zz (vendor/), with the LGPL license notice next to it
cp vendor/7zz "$APP/Contents/Resources/7zz"
cp Resources/7zip-LICENSE.txt "$APP/Contents/Resources/7zip-LICENSE.txt"
# one folder per language: UI strings, document type names, and AppKit's own texts (alerts, "Open Recent")
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# 7zz ships unsigned; sign the inner executable first, then the bundle
codesign --force --sign - "$APP/Contents/Resources/7zz"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP ($commit)"

if $install; then
    DEST=/Applications/Kompac.app
    [[ -d "$DEST" ]] && rm -r "$DEST"
    ditto "$APP" "$DEST"
    # re-register: refreshes the icon and document types Launch Services had cached from the old copy
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "Installed: $DEST"
    pgrep -xq Kompac && echo "Kompac is open: the old version keeps running until you quit it (⌘Q) and reopen it."
else
    echo "To open an archive: open -a $PWD/$APP archive.zip"
fi
