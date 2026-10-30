### Guidelines

- [x] I am the developer of the app. (If not, please explain the developer's stance on this inclusion request in the Further Notices section.)
- [x] The app complies with the [App Inclusion Policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/).
- [x] The app is not already listed in the repo or issue tracker.
- [x] The [Fastlane](https://izzyondroid.org/docs/general/Fastlane/) folder is available in the app's repo.

### Link to the source code

https://github.com/lucinhu/LRDP

### Link to app in another app store

Not yet listed in another Android app store. F-Droid submission is prepared but not merged yet.

### License used

Apache-2.0

### Categories

Internet

### Summary

Lightweight, local-first RDP client with an embedded FreeRDP backend.

### Description

LRDP (Lightweight Remote Desktop Protocol) is a lightweight, local-first RDP client for Android. It connects to RDP servers and runs the remote desktop inside the app: FreeRDP provides the protocol implementation and Flutter provides the interface, so no external RDP client is involved.

Features:
- Connection manager with quick connect, groups, favourites, search, recent sessions and `.rdp` file import/export
- Full-screen sessions with a draggable, collapsible floating toolbar
- Touch, trackpad and gesture input: two-finger scroll, right click, pinch zoom and drag; the remote screen stays usable while the keyboard is open
- Text input and IME support with modifier keys (Ctrl, Shift, Alt, Win) for single-shot or locked combinations
- Clipboard and file transfer (text and images both ways, local file paste, file staging area)
- Session restore with bounded, cancellable reconnect; optional audio redirection
- Automatic and dynamic resolution, smooth/sharp scaling, remote cursor and H.264 software decoding
- Certificate fingerprint confirmation; passwords stored in Android secure storage, never in config exports, logs or command lines
- System light/dark theme, English and Chinese UI

No accounts, no ads, no analytics, no trackers, no self-updater.

### Build instructions

The release APK is built from source with Flutter 3.47.7, the Android NDK r28c (28.2.13676358) and static OpenSSL 3.6.5 / FFmpeg 9.0.2 for arm64-v8a. Full steps are in `docs/BUILDING.md`:

```
git clone https://github.com/lucinhu/LRDP.git
cd LRDP
flutter pub get
# build static OpenSSL 3.6.5 for android-arm64 and FFmpeg 9.0.2 (scripts/build_android_openssl.sh,
# scripts/build_ffmpeg.sh), then:
export ANDROID_NDK_ROOT=$HOME/Android/Sdk/ndk/28.2.13676358
export LRDP_OPENSSL_ROOT=$PWD/build/deps/android-openssl
export LRDP_FFMPEG_ROOT=$PWD/build/deps/ffmpeg/android
export LRDP_ANDROID_KEYSTORE=/path/to/your-release.jks
export LRDP_ANDROID_KEY_ALIAS=lrdp
export LRDP_ANDROID_STORE_PASSWORD=...
export LRDP_ANDROID_KEY_PASSWORD=...
env 'ORG_GRADLE_PROJECT_lrdp.ndkVersion=28.2.13676358' \
  flutter build apk --release --target-platform android-arm64 --build-name=0.3.0 --build-number=6
```

Signed APK attached to the GitHub release: https://github.com/lucinhu/LRDP/releases/download/v0.3.0-preview.1/lrdp-0.3.0-android-arm64-release.apk
(SHA-256 `3ca9528b59073373fd0874b632c704738f18ef2464106a43cfcd97539510ce8d`; certificate SHA-256 `91:30:4E:3C:17:60:9C:FC:27:E0:1E:B8:67:B5:35:3D:10:F0:D5:F7:0F:22:07:03:C4:C0:E2:0F:88:0A:09:ED`).

### Assistance Level

Minimal – Occasional suggestions or lookups

### "AI" Tool(s)

<!-- TODO(lucinhu): list every AI tool that contributed to the app code, or write "None". -->

### What did the tools help with, and how?

<!-- TODO(lucinhu): describe honestly which parts were AI-assisted. -->

### AI Accountability

- [ ] The human developer(s) reviewed and edited all "AI"-generated outputs
- [ ] The human developer(s) ran manual tests and manually verified all changes

### Further Notices

- The app is the original work of the developer and is not a fork.
- Android permission list: only `INTERNET` plus the AndroidX-internal `dev.lrdp.lrdp.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`.
- The repository also publishes a Linux AppImage and an AUR package (`lrdp-bin`); Android is the platform requested here.
- The F-Droid submission was closed because the project is younger than three months; it will be resubmitted later. IzzyOnDroid is the preferred interim distribution channel.
