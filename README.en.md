# LRDP

[简体中文](README.md) · English

LRDP (Lightweight RDP) is a lightweight, local-first RDP client built with **Flutter + FreeRDP**. FreeRDP runs embedded in the app, so no external RDP client is involved.

The current version is a **0.2.0 development preview**, targeting Linux, Android, Windows, macOS and iOS. Build and verification progress for each platform is listed in the table below.

[Download preview](https://github.com/lucinhu/LRDP/releases/tag/v0.2.0-preview.1) · [Usage guide](docs/USAGE.md) · [Building guide](docs/BUILDING.md) · [Clipboard and files](docs/CLIPBOARD.md) · [Verification record](docs/VERIFICATION.md)

![LRDP desktop connection library with an example profile](docs/screenshots/workspace.png)

## Mobile interface

<table>
  <tr>
    <th>Connection list</th>
    <th>Full-screen session and floating toolbar</th>
    <th>Text input and special keys</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/android-workspace.png" alt="Android connection list with search, quick connect, favorites and recent connections" width="240"></td>
    <td><img src="docs/screenshots/android-fullscreen-tools.png" alt="Floating toolbar expanded during an Android full-screen remote session" width="240"></td>
    <td><img src="docs/screenshots/android-ime-control-text.png" alt="Android text input screen, using special keys and operating the remote desktop at the same time" width="240"></td>
  </tr>
</table>

The screenshots above were taken on the Android emulator using a local loopback test connection. The color blocks in the remote desktop are the test desktop; the input screenshots show a test IME, and the actual soft keyboard varies by device and input method.

## Main features

- **Check for updates**: manually check stable or preview releases from GitHub Releases, read the notes and open the download for your platform and architecture; private repositories can use a read-only token stored in secure storage.
- **Connection management**: quick connect, groups, favorites, search, recent connections, switching between multiple sessions, and `.rdp` profile import/export.
- **Phone controls**: full-screen sessions, a draggable and collapsible floating toolbar, trackpad and direct touch, two-finger scrolling, right-click, zoom and drag. The remote desktop stays usable while the keyboard is expanded.
- **Text and keyboard**: Chinese input, pasting whole passages and simulated soft-keyboard keys. Ctrl, Shift, Alt and Win support one-shot combinations and locked holding, and the extended row switches between digits/symbols and navigation/function keys.
- **Display**: automatic resolution, dynamic resolution changes, zoom and pan, smooth/sharp scaling, remote mouse cursor, H.264 software decoding, and a display frame-rate cap that follows the screen refresh rate.
- **Clipboard and files**: text and bidirectional picture clipboard, pasting local files to the remote, and copying files both ways through the file transfer station.
- **Appearance and language**: system color scheme, light/dark themes that follow the system, and support for Simplified Chinese, Traditional Chinese and English.
- **Session recovery and audio**: reconnect on connection loss with a retry limit that can be cancelled; optional remote audio playback that pauses when leaving the session and resumes when returning.
- **Credentials and certificates**: passwords use the system secure storage, and exported profiles contain no passwords. Certificate fingerprints must be confirmed explicitly, and can be trusted for this session only or saved.

Dynamic resolution, clipboard, file and audio features require server support and the corresponding redirection to be enabled. The display frame-rate cap can be set up to 240 fps; the actual frame rate depends on the remote output, screen, network and device performance.

## Platform status

| Platform | Current progress |
| --- | --- |
| Linux | An x86_64 AppImage built on Ubuntu 22.04 is available, and Linux desktop acceptance is complete: FUSE/extract-and-run launch, window, input, full-screen and loopback RDP were verified in a private Arch X11 session. |
| Android | The current release provides an ARM64 APK, and Android acceptance is complete, covering touch, gestures, soft-keyboard input, clipboard and file transfer, session recovery and audio; an x86_64 test build existed earlier. |
| Windows | Native build and display integration are in place; the x64 connection core and parts of the protocol and file-handle handling passed Wine tests. The Flutter main window and real Windows systems are pending verification. |
| macOS | Project and native bridge are in place; build and device verification are pending. |
| iOS | Project and native bridge are in place; build and device verification are pending. |

Verification scope differs between features; exact versions, test methods and limitations are recorded in [VERIFICATION.md](docs/VERIFICATION.md). File clipboard interoperability with Windows RDP, xrdp and GNOME still needs testing.

## Getting started

On Linux x86_64, download the `.AppImage` from Releases and run it directly after making it executable:

```sh
chmod +x lrdp-0.2.0-linux-x64.AppImage
./lrdp-0.2.0-linux-x64.AppImage
```

The AppImage bundles application runtime libraries such as GTK and OpenSSL; it requires glibc ≥ 2.35 and a working OpenGL/EGL environment.
If the system has no FUSE, start it with `APPIMAGE_EXTRACT_AND_RUN=1 ./lrdp-0.2.0-linux-x64.AppImage`.
Android users download the ARM64 preview APK. Each package is released together with the full source, build information and SHA-256 checksum files.

1. Tap “Add computer” and enter the address, username, password and domain information if needed. The address can include the port directly, for example `192.168.1.10:3390`; for IPv6 use `[2001:db8::1]:3389`.
2. In “Connection preferences”, enable shared clipboard, file transfer or remote audio as needed. Remote resolution defaults to automatic and can also be set manually.
3. The first time a certificate needs confirmation, check the server's SHA-256 fingerprint and then choose how to trust it. After saving the connection, tap the computer card to enter the session.

Sessions start full screen, and common actions are collected in the floating toolbar. Returning to the connection list keeps the session; on desktop, switch connections with tabs. In desktop full screen, release-control and exit buttons are at the top left; `Ctrl + Alt + Home` releases the mouse and keyboard, and `Ctrl + Alt + Enter` toggles full screen.

## Touch and keyboard input on phones

Trackpad mode suits small remote controls; direct touch mode taps at the corresponding position on the screen.

| Trackpad gesture | Action |
| --- | --- |
| One-finger swipe | Move the remote cursor |
| One-finger tap | Left click |
| Double-tap, then hold the second touch and drag | Drag with the left button held |
| Two-finger tap | Right click |
| Two-finger vertical or horizontal swipe | Scroll vertically or horizontally |
| Two-finger pinch | Zoom the view |

When zoomed in, the view follows the cursor as it approaches the screen edge. Physical desktop trackpads also support two-finger scrolling and pinch zoom.
The “Trackpad pointer speed” setting offers 50%–200% and does not affect direct touch or two-finger scrolling;
“Zoom display” selects smooth or sharp pixels and only changes local rendering, not the encoded quality on the server.

Open “Keyboard” in the toolbar to choose a mode for the input situation:

| Input mode | When to use |
| --- | --- |
| Text input | Type with the local input method and tap send; the text is submitted through Unicode key events. |
| Paste input | Send the whole passage through the shared clipboard; suited to remote applications that do not accept direct Unicode input. |
| Keyboard simulation | Send English letters, digits, symbols and editing keys immediately; you can also type Pinyin and let the remote input method compose characters. |

Keyboard simulation is the default and the most recent mode is remembered. Keyboard simulation hides the local text field and supports Enter, Backspace and arrow key events. Unsent text drafts survive collapsing, reopening and mode switches, and are kept only in the current session's memory. The lock switch above the soft keyboard decides whether modifier keys are used once or stay held; after expanding the second row, tap the digit button to switch between digits/symbols, and the input method is preserved when switching. The remote desktop stays touchable while typing. See the [usage guide](docs/USAGE.md) for details.

[Phone connection list](docs/screenshots/phone-workspace.png) · [Phone session tools](docs/screenshots/phone-remote.png) · [Android emulator Chinese input](docs/screenshots/android-keyboard.png) · [Landscape keyboard](docs/screenshots/android-landscape-keyboard.png)

## Clipboard and files

Enable “Shared clipboard” before connecting, then choose the operation you need:

| Content | How to use |
| --- | --- |
| Local text | Tap the remote input position, then choose “More → Paste local text”. |
| Picture content | Choose “More → Paste local picture” or “Select picture to paste”; pictures copied on the remote can be synced to the local clipboard of the active session. |
| Local files | Open the target folder on the remote first, then choose “More → Select files to paste”. |
| Bidirectional file copy | Enable “File transfer” in the connection preferences and reconnect, then exchange files through the “file transfer station”. |

File paste preserves the original file bytes and file names and supports Chinese names, multiple files and empty files. Up to **32 files** per operation, **256 MiB** per file and **512 MiB** in total. Keep the connection open until the remote file manager finishes copying; “paste request sent” does not mean the remote side has saved the files.

On the remote Windows machine the transfer station is available at `\\tsclient\LRDP`. When the remote is Linux, access depends on the RDP server in use. Picture paste transfers the picture contents; use file paste or the transfer station when you need the original picture file.

Remote file clipboard download, reading the “copy files” content of the local file manager, and folder paste are not implemented yet. Use the transfer station for the reverse direction. See [Clipboard and file transfer](docs/CLIPBOARD.md) for complete steps and limitations.

## Running from source

Requires Flutter ≥ 3.41, Dart ≥ 3.11, CMake ≥ 3.22, Ninja, a C/C++ toolchain, OpenSSL 3, and the Flutter build dependencies for the target platform.

The example below uses Linux:

```sh
git clone --recurse-submodules https://github.com/lucinhu/LRDP.git
cd LRDP
flutter pub get
bash scripts/build_ffmpeg.sh linux-x64
export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/linux-x64"
flutter run -d linux
```

For an existing workspace, initialise the dependencies with `git submodule update --init --recursive`. FreeRDP 3.32.2 is pinned in the `third_party/FreeRDP` submodule; the adaptation code is maintained separately and keeps the upstream source unchanged. H.264 uses FFmpeg 9.0.2 as a minimal static software decoder.

Linux system dependencies, the Android SDK/NDK and signing, the Windows toolchain and the Apple platform build steps are described in [BUILDING.md](docs/BUILDING.md).

## Development and verification

```text
lib/                    Flutter UI, connection profiles, worker isolate and FFI
native/                 C ABI, protocol adaptation, connection thread and lifecycle
packages/lrdp_native/   Native build and display integration per platform
third_party/FreeRDP/    Pinned upstream Git submodule
scripts/                Dependency builds, packaging and isolated protocol tests
```

Routine checks use `flutter analyze` and `flutter test`. Native changes also require CTest and isolated loopback protocol tests; the steps are in the [building guide](docs/BUILDING.md) and actual results in the [verification record](docs/VERIFICATION.md).

Protocol tests use private services and virtual desktops; unit tests, protocol passing and platform device verification are recorded separately. See [development progress](docs/ROADMAP.md) for upcoming work; RD Gateway, RemoteApp, multiple monitors and hardware video decoding are still to be implemented.

## License

LRDP is licensed under [Apache-2.0](LICENSE). Third-party components such as FreeRDP, FFmpeg and OpenSSL follow their own licenses; see [NOTICE](NOTICE) and the [third-party license files](assets/licenses/).
