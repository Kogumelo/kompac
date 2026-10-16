# Kompac

**English** · [Português](README.pt-BR.md)

Archive viewer, extractor and compressor for macOS, with no telemetry.
Opens ZIP, 7z, RAR (4 and 5, with password), tar, tar.gz/tgz, tar.bz2, tar.xz/txz, zstd, ISO and DMG.
Creates only four: ZIP, 7z, tar.gz and tar.xz.

- **Phase 1 — reading:** open, browse the contents as a tree, preview text without extracting, and
  extract everything or only the selection.
- **Phase 2 — compressing:** File › New (⌘N).

Code, comments and identifiers are in English; the user interface is in English and
Portuguese (see [Localization](#localization)).

## Usage

```sh
./build.sh             # builds Kompac.app here
./build.sh --install   # and copies it to /Applications (the copy Finder's "Open With" uses)
```

`build.sh` stamps the build number (commit count) and the commit (`KompacCommit`, with `-dirty` when
a tracked file has changed) into `Info.plist`; both show up in Kompac › About Kompac.

**Deploy through Kommand (the maintainer's install command):** the project declares
`production = "/km-instalar"`. The skill (`.claude/commands/km-instalar.md`) checks that the checkout
is on `main` and clean, runs `swift test`, runs `./build.sh --install` and checks the stamp, icon,
`7zz` and signature of what was installed. It does not write to git.

To open an archive, use Finder (Open With › Kompac), drag the archive onto the Dock icon, or use
File › Open (⌘O). The types are registered as alternates, so Kompac does not become the default app
on its own. To make it the default: Get Info › Open with › Kompac › Change All.

- **Extract Selected (⌘E) / Extract All (⇧⌘E):** the default destination is the archive's folder.
  If a single item comes out (a folder or a file), it goes straight to the destination; if several
  come out, they go into a subfolder named after the archive. Nothing is overwritten: if the name
  exists, it becomes "name 2". 7zz first extracts into a hidden `.kompac-…` folder next to the
  destination, so cancelling or an error never leaves a half-done extraction.
- **Preview:** clicking a file shows its first 16 KB if it is text, read into memory
  (`7zz e -so`). If it is not text, it shows the type and size.
- **Names in:** Windows ZIPs without the UTF-8 flag store names in CP850/CP437 or Windows-1252,
  and they show up as "Relat≤rio". Automatic mode detects the code page and fixes it, including
  the names written to disk when extracting.
- **Password:** asked for in a panel inside the window, when opening (encrypted names) or when
  extracting.

### Compressing (File › New, ⌘N)

Opens an empty window: drag files and folders into it (or use Choose…). Each item goes at the top
of the archive under its own name.

| Format | What for | Password |
|---|---|---|
| **ZIP** (default) | maximum compatibility | AES-256; **ASCII only** (a 7zz limit: with an accent or €, it refuses) |
| **7z** | maximum compression | AES-256, with an option to **encrypt the names** (`-mhe=on`); accepts accents |
| **tar.gz** | Linux servers | none |
| **tar.xz** | Linux, smallest size | none |

- Compression: Fast (`-mx=1`), Normal (`-mx=5`), Maximum (`-mx=9`).
- Name and destination: the default is the item's name (several items: "Archive") and the
  originals' folder. Nothing is overwritten: if the name exists, it becomes "Archive 2.zip".
- `.DS_Store`, `._*` (resource forks) and `__MACOSX` never go in (`-xr!…` in 7zz).
- 7z can be split into parts (`name.7z.001`, `.002`…). 7zz's split ZIP is not Windows' standard
  `.z01`, so it is not offered.
- 7zz writes to a hidden `.kompac-…` file in the destination, which only gets the chosen name at
  the end. Cancelling or an error deletes the partial file (and the parts).
- tar.gz/tar.xz: two 7zz processes connected by a pipe (`a -ttar -so` → `a -tgzip -si`/`-txz -si`),
  with no intermediate .tar on disk.
- 7zz 26.04 **does not create** zstd (`E_NOTIMPL`), it only reads it.

### From the Finder (right-click)

Two items in the menu of any file or folder:

- **Compress to “name.zip”:** ZIP, Normal level, next to the originals, without asking anything.
  The window only shows the progress and closes when done; on an error or a 7zz warning it stays
  open with the notice.
- **Compress with Kompac…:** opens the New window with the selected items.

It is a Finder extension (`Contents/PlugIns/KompacFinder.appex`, FinderSync type, the same kind of
item other archivers put there). Finder only loads it sandboxed, and the sandbox keeps it from running
7zz on the user's files: it just builds a `kompac://compress?action=zip|window&path=…` URL
(`FinderRequest`) and opens it with the Kompac.app it lives in. `build.sh --install` registers it and
turns it on (`pluginkit -e use`), since third-party Finder extensions start off; to turn it off:
System Settings › General › Login Items & Extensions › Finder. If the menu does not show up right
after installing: `killall Finder`.

## Structure

| Folder | What |
|---|---|
| `Sources/KompacCore` | UI-free core: runs `7zz`, reads `7zz l -slt`, extracts and compresses (`Compression.swift`) with progress (`-bsp1`) and cancellation, does the preview and converts names |
| `Sources/Kompac` | AppKit + SwiftUI app, one read-only `NSDocument` per open archive; the New window (`CompressView`/`CompressModel`) is not a document |
| `Sources/KompacFinder` + `FinderExtension/` | the Finder extension (right-click menu): code, its `Info.plist` and its sandbox entitlement |
| `Resources/<lang>.lproj` | UI strings (`Localizable.strings`) and document type names (`InfoPlist.strings`), one folder per language |
| `Tests/KompacCoreTests` | `swift test`; the fixtures are generated by `Tests/make-fixtures.sh` |
| `icon/` | `kompac.svg` (drawing), `kompac-16.svg` (16 px drawing) and `Kompac.icns` (versioned); `make-icon.sh` regenerates the .icns when the drawing changes |
| `.claude/commands/km-instalar.md` | the deploy: from `main` to `/Applications` |
| `vendor/7zz` | official 7-Zip 26.04 for macOS (universal), from https://www.7-zip.org |
| `Resources/7zip-LICENSE.txt` | 7-Zip license (GNU LGPL + unRAR restriction), copied into the app |

## Localization

The user interface follows the macOS language: English by default, Portuguese (pt-BR) available.
The strings live in `Resources/<lang>.lproj/Localizable.strings`, with the English text as the key
(`NSLocalizedString("Extract", …)` in the code); document type names live in `InfoPlist.strings`,
in the same folder. `build.sh` refuses to build if any key used in the source is missing from any
language.

To add a language:

1. Copy `Resources/en.lproj` to `Resources/<lang>.lproj` (for example `es.lproj`).
2. Translate the values (the right-hand side of `=`) in `Localizable.strings` and
   `InfoPlist.strings`; leave the keys as they are.
3. Add the language code to `CFBundleLocalizations` in `Info.plist`.

## Engine: 7zz

Kompac uses 7-Zip's official command-line binary instead of the system's libarchive. 7zz opens
password-protected RAR5 and creates 7z with encrypted names, and libarchive does neither.

- Version 26.04 (2026-10-05), `7z2604-mac.tar.xz` from the official GitHub (ip7z/7zip).
  Package SHA-256: `bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578`;
  `7zz` SHA-256: `36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577`.
- To update, replace `vendor/7zz` and `Resources/7zip-LICENSE.txt` and run `swift test`.
- Behaviours checked on 26.04 that the code depends on:
  - A name that is not valid UTF-8 becomes U+EF00+byte (0xF3 → U+EFF3), in the listing and on disk.
    The `-mcp=` option does not change that on the Mac, so the conversion is done in the core.
  - xz does not store the inner name: 7zz lists the item without `Path`, and the tar is recognised
    by the outer name (`x.tar.xz`).
  - When creating, an empty `-p` makes 7zz ask for the password on the keyboard: without a
    password, `-p` is not passed.
  - 7zz only sees the outer layer of a tar.gz. That is why tar.gz/xz/bz2/zst go through two 7zz
    processes connected by a pipe (`x -so` → `l`/`x -si -ttar`).
  - DMG: 7zz opens the APFS image inside. `-sns-` avoids `name:com.apple.provenance` files.

Tests: `swift test`. To also test a real, large RAR, point `KOMPAC_REAL_RAR` at it:
`KOMPAC_REAL_RAR=/path/to/big.rar swift test` runs the listing test. The full extraction only runs
with `KOMPAC_REAL_RAR=/path/to/big.rar KOMPAC_BIG_EXTRACT=<temporary folder> swift test --filter realRARExtraction`;
it checks that every listed file comes out with the listed size and deletes what it extracted at
the end.

App self-test through Launch Services (the same path Finder takes), which lists and quits:
`open -n -W -a Kompac.app --env KOMPAC_SELFTEST=/tmp/out.txt archive.zip`
(with `--env KOMPAC_SELFTEST_PASSWORD=…` for a password-protected archive).

Self-test of the New window, which compresses and quits:
`open -n -W -a "$PWD/Kompac.app" --env KOMPAC_SELFTEST_COMPRESS=/tmp/out.txt --env "KOMPAC_SELFTEST_SOURCES=/path/folder|/path/file" --env KOMPAC_SELFTEST_FORMAT=7z`
(formats: `zip`, `7z`, `tar.gz`, `tar.xz`; `KOMPAC_SELFTEST_PASSWORD` optional).

## License

[MIT](LICENSE), © 2026 Kogumelo Informática Ltda. Use, copy and modify it
freely, keeping the copyright notice. The code comes with no warranty.

Third-party parts keep their own licenses: the bundled 7-Zip engine (`vendor/7zz`) is
© Igor Pavlov under the GNU LGPL with the unRAR restriction (`Resources/7zip-LICENSE.txt`,
also copied into the app), and the RAR test files in `Tests/KompacCoreTests/Fixtures/` come from
libarchive under the BSD license (`SOURCE.txt` alongside).
