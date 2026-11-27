# Slit

A macOS menu-bar reading aid. Slit dims (or blurs) the page around the text
you are reading, leaving a narrow opening that follows your eye, so lines stop
competing for attention. It can also redraw the revealed words in
OpenDyslexic, word by word.

Slit reads the text under your pointer by capturing that part of the screen
and running Apple's Vision OCR on it. Nothing is recorded, stored, or sent
anywhere. The only network request Slit makes is checking for updates, and only
when you choose **Check for Updates…** (or turn on automatic checks in
Settings).

## Download (no Xcode needed)

1. Download **`slit.dmg`** from the
   [latest release](https://github.com/Ryukun1/slit/releases/latest).
2. Open it and drag **Slit** onto **Applications**.
3. Open Slit. macOS blocks it the first time, because Slit isn't notarized by
   Apple yet: click **Done**, then go to **System Settings → Privacy &
   Security**, scroll down and click **Open Anyway**. If there's no Open
   Anyway button, run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Slit.app
   ```

4. Grant the two permissions Slit asks for (see
   [step 4 below](#4-open-it-and-grant-permissions)).

Each release lists the DMG's SHA-256 checksum, so you can check your download
with `shasum -a 256 ~/Downloads/slit.dmg`.

## Build from source

Prefer to build it yourself? It takes about five minutes, most of it waiting
for Xcode.

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

- **Slit 1.1 or later:** click Slit's menu-bar icon and choose **Check for
  Updates…**. Slit downloads the new version, checks its signature, replaces
  itself and restarts. The same button is in Settings → Updates, along with an
  option to check automatically (off by default).
- **Slit 1.0:** it has no update button. Download the latest DMG and replace
  the app once, as in [Download](#download-no-xcode-needed).
- **Built from source:** `git pull`, then `./build_app.sh --install`.

Slit isn't signed with an Apple Developer ID yet, so macOS treats each new
version as a new app and drops its permissions. After updating, switch Slit
off and on again under Screen Recording and Accessibility (or remove it from
those lists and re-add it).

## Troubleshooting

- **`SwiftUIMacros.StateMacro could not be found`**: you're building with the
  Command Line Tools only. Install Xcode and run the `xcode-select` command in
  step 1.
- **Slit does nothing when I hold ⌘**: check that both permissions are on and
  that you reopened Slit after granting them.
- **"Slit" can't be opened, or "Slit is damaged"**: this happens to a
  downloaded copy the first time. Use **Open Anyway** or the `xattr` command
  in [Download](#download-no-xcode-needed). A copy you built yourself isn't
  affected.
- **The download says the connection isn't safe**: some networks (often
  university or company ones) block GitHub's download server. Don't click
  through; download on another network, such as a phone hotspot.
- **Slit stopped working after an update**: switch it off and on again under
  Screen Recording and Accessibility.

## Development

```bash
swift build   # debug build
swift test    # run the test suite
```

## Releasing

Every push is built and tested on GitHub Actions (`.github/workflows/build.yml`),
and the DMG is attached to the run. To publish a version:

```bash
git tag v1.2
```

```bash
git push origin v1.2
```

`.github/workflows/release.yml` then builds and tests it, signs the DMG with
the Sparkle update key (the `SPARKLE_ED_PRIVATE_KEY` repository secret; the
maintainer's copy is in the login keychain), publishes the GitHub Release and
adds the version to [`appcast.xml`](appcast.xml), the feed **Check for
Updates…** reads.

To ship builds that open with no Gatekeeper warning, sign with a Developer ID
Application certificate and notarize: `./build_app.sh --notarize` (see the
comments at the top of the script).

## Licenses

- Slit's source: MIT, see [LICENSE](LICENSE).
- OpenDyslexic fonts in `Sources/Resources/` are
  © Abbie Gonzalez, used under the SIL Open Font License 1.1.
  See [OFL-OpenDyslexic.txt](OFL-OpenDyslexic.txt).
