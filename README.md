# Slit

A macOS menu-bar reading aid. Slit dims (or blurs) the page around the text
you are reading, leaving a narrow opening that follows your eye, so lines stop
competing for attention. It can also redraw the revealed words in
OpenDyslexic, word by word.

Slit reads the text under your pointer by capturing that part of the screen
and running Apple's Vision OCR on it. Nothing is recorded, stored, or sent
anywhere; the app makes no network requests.

## Install

There is no ready-made download yet, so you build Slit yourself. It takes about
five minutes, most of it waiting for Xcode.

### 1. What you need

- A Mac running **macOS 14 (Sonoma) or later**
- **Xcode** (free from the Mac App Store). The Command Line Tools alone are
  not enough: Slit uses SwiftUI macros that only ship with the full Xcode.

Open Xcode once so it can finish installing its components, then point the
command line at it and accept the license:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

```bash
sudo xcodebuild -license accept
```

### 2. Download the code

```bash
git clone https://github.com/Ryukun1/slit.git
```

```bash
cd slit
```

No git? Use **Code → Download ZIP** on the GitHub page, unzip it, and `cd`
into the folder.

### 3. Build and install

```bash
./build_app.sh --install
```

This compiles Slit and copies `Slit.app` into `/Applications`. If macOS says
the script isn't executable, run `chmod +x build_app.sh` first.

To build without installing, run `./build_app.sh`. The app appears as
`Slit.app` in the project folder.

### 4. Open it and grant permissions

```bash
open /Applications/Slit.app
```

Slit lives in the menu bar (it has no Dock icon). On first launch it asks for
two permissions in **System Settings → Privacy & Security**:

- **Screen Recording**: to read the text you point at.
- **Accessibility**: to respond to keyboard shortcuts and scrolling.

Turn both on for Slit, then reopen it if macOS asks you to.

## Using Slit

| To do this | Do this |
|---|---|
| Start | Hold **⌘** and click a paragraph |
| Draw your own region | **⌥** + drag |
| Next / previous line | **↓** / **↑** |
| Stop | **esc** |

More options (dim or blur, how many lines stay visible, auto-advance,
OpenDyslexic, colors) are in Slit's Settings from the menu-bar icon.

## Updating

```bash
cd slit
git pull
./build_app.sh --install
```

Because your build is signed ad hoc, macOS treats each update as a new app
and drops the permissions. After updating, switch Slit off and on again under
Screen Recording and Accessibility (or remove it from those lists and re-add
it). Slit's permissions screen can also reset its own entries for you.

## Troubleshooting

- **`SwiftUIMacros.StateMacro could not be found`**: you're building with the
  Command Line Tools only. Install Xcode and run the `xcode-select` command in
  step 1.
- **Slit does nothing when I hold ⌘**: check that both permissions are on and
  that you reopened Slit after granting them.
- **"Slit" can't be opened because Apple cannot check it**: this only happens
  to a copy downloaded from somewhere else. A copy you built yourself isn't
  quarantined, so build it from source as above.

## Development

```bash
swift build   # debug build
swift test    # run the test suite
```

## Distribution

Builds for other people's Macs must be signed with a Developer ID Application
certificate and notarized: `./build_app.sh --notarize` (see the comments at
the top of the script).

## Licenses

- Slit's source: MIT, see [LICENSE](LICENSE).
- OpenDyslexic fonts in `Sources/Resources/` are
  © Abbie Gonzalez, used under the SIL Open Font License 1.1.
  See [OFL-OpenDyslexic.txt](OFL-OpenDyslexic.txt).
