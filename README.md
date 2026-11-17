# Slit

A macOS menu-bar reading aid. Slit dims the page around the text you are
reading, leaving a narrow opening that follows your eye, so lines stop
competing for attention. It can also redraw the revealed words in
OpenDyslexic, word by word.

Slit reads the text under your pointer by capturing that part of the screen
and running Apple's Vision OCR on it. Nothing is recorded, stored, or sent
anywhere; the app makes no network requests.

## Requirements

- macOS 14 or later
- Full Xcode (SwiftUI macros need it; Command Line Tools alone cannot build this)

## Build

```bash
swift build          # debug build
swift test           # run the test suite
./build_app.sh       # produce Slit.app (release)
./build_app.sh --install   # also copy to /Applications
```

`build_app.sh` signs with the best certificate it finds (Developer ID, then
Apple Development, then ad-hoc). macOS ties its permission grants to the
signature, so ad-hoc builds lose their grants on every rebuild.

## Permissions

Slit asks for two permissions on first launch:

- **Accessibility**: to respond to keyboard shortcuts and scrolling.
- **Screen Recording**: to read the text you point at.

## Distribution

Builds for other people's Macs must be signed with a Developer ID
Application certificate and notarized: `./build_app.sh --notarize`
(see the comments at the top of the script).

## Licenses

- Slit's source: MIT, see [LICENSE](LICENSE).
- OpenDyslexic fonts in `Sources/Resources/` are
  © Abbie Gonzalez, used under the SIL Open Font License 1.1.
  See [OFL-OpenDyslexic.txt](OFL-OpenDyslexic.txt).
