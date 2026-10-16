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
swift build -c release --product KompacFinder
BINDIR="$(swift build -c release --show-bin-path)"

APP=Kompac.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# build number = commit count; KompacCommit = short hash (+ "-dirty" when tracked files differ from it),
# shown in About Kompac
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" \
    -c "Add :KompacCommit string $commit" "$APP/Contents/Info.plist"
cp "$BINDIR/Kompac" "$APP/Contents/MacOS/Kompac"
# app icon: generated from icon/kompac.svg by icon/make-icon.sh
cp icon/Kompac.icns "$APP/Contents/Resources/Kompac.icns"
# engine: the official 7-Zip 7zz (vendor/), with the LGPL license notice next to it
cp vendor/7zz "$APP/Contents/Resources/7zz"
cp Resources/7zip-LICENSE.txt "$APP/Contents/Resources/7zip-LICENSE.txt"
# one folder per language: UI strings, document type names, and AppKit's own texts (alerts, "Open Recent")
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Finder extension ("Compress to …zip" / "Compress with Kompac…" in the right-click menu), same build number
EXT="$APP/Contents/PlugIns/KompacFinder.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp FinderExtension/Info.plist "$EXT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$EXT/Contents/Info.plist"
cp "$BINDIR/KompacFinder" "$EXT/Contents/MacOS/KompacFinder"
cp -R Resources/*.lproj "$EXT/Contents/Resources/"
# 7zz ships unsigned; sign the inner executables first (the extension with its sandbox), then the bundle
codesign --force --sign - "$APP/Contents/Resources/7zz"
codesign --force --sign - --entitlements FinderExtension/KompacFinder.entitlements "$EXT"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP ($commit)"

if $install; then
    DEST=/Applications/Kompac.app
    [[ -d "$DEST" ]] && rm -r "$DEST"
    ditto "$APP" "$DEST"
    # re-register: refreshes the icon and document types Launch Services had cached from the old copy
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    # Finder extension: opening a test build (here or in a worktree) registers its copy too, under the
    # same identifier. Drop every copy outside /Applications, register the installed one and turn it
    # on — third-party Finder extensions start off.
    pluginkit -m -v -i br.com.kogut.kompac.finder 2>/dev/null | awk -F'\t' '{print $NF}' | grep '\.appex$' |
        while IFS= read -r old; do
            [[ "$old" == "$DEST/"* ]] || pluginkit -r "$old" 2>/dev/null || true
        done
    pluginkit -a "$DEST/Contents/PlugIns/KompacFinder.appex"
    pluginkit -e use -i br.com.kogut.kompac.finder
    echo "Installed: $DEST"
    pgrep -xq Kompac && echo "Kompac is open: the old version keeps running until you quit it (⌘Q) and reopen it."
else
    echo "To open an archive: open -a $PWD/$APP archive.zip"
fi
