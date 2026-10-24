# MR description for `New app: LRDP` (fdroiddata)

This is the template-compliant description prepared for the resubmission of
`New app: LRDP` (previous MR !53893 was closed because the app had not been
publicly developed for three months yet; see `docs/fdroid-report.md`).

---

## Abstract for new app inclusion

### Please introduce the functions and usage of your app in summary, and also attach some screenshots.

LRDP (Lightweight Remote Desktop Protocol) is a lightweight, local-first RDP
client for Android. It is built with Flutter for the interface and an embedded
FreeRDP backend for the protocol, so the remote desktop runs inside the app and
no external RDP client is started.

Main features: connection profiles with groups, search, favourites and recent
connections; full-screen sessions with a draggable, collapsible floating
toolbar; trackpad and direct-touch input, two-finger scrolling, right click,
pinch zoom and drag; on-screen modifier keys (Ctrl/Shift/Alt/Win) with one-shot
and locked modes; Chinese/English text input and paste; clipboard text and image
sync; file transfer through the RDP clipboard; automatic and dynamic
resolution; bounded, cancellable reconnect and session restore; optional remote
audio; certificate fingerprint confirmation; system light/dark theme; English,
Simplified Chinese and Traditional Chinese UI.

Usage: add a connection (host, port, username, optional domain), tap it to
connect, then use the floating toolbar for keyboard, mouse, display and
clipboard actions. Passwords are stored in the Android secure storage; exported
profiles never contain passwords.

Screenshots (upstream fastlane metadata):
<https://github.com/lucinhu/LRDP/tree/v0.2.0-preview.1/fastlane/metadata/android/en-US/images>

### Please elaborate why you wrote this app. Please highlight the unique functions it provides over other similar apps in F-Droid.

I wrote LRDP because the Android RDP clients I tried either launch or wrap an
external client, show ads, or handle touch input poorly. LRDP embeds FreeRDP
directly and treats the touch screen as the primary input device: the floating
toolbar, one-shot/locked modifier keys, gesture mapping (two-finger scroll,
right click, pinch zoom) and the ability to keep using the remote desktop while
the soft keyboard is open are all designed for phone use. It has no account, no
ads and no tracking, and all configuration stays on the device.

## Checklist

### Policy

* [x] The app complies with the [inclusion criteria](https://f-droid.org/docs/Inclusion_Policy).
* [x] The original app author has been notified (and does not oppose the inclusion). If you are not the author, please paste the link of the reply from the author. — I am the author.
* [x] The upstream app source code repo contains the app metadata in a [Fastlane](https://gitlab.com/snippets/1895688) or [Triple-T](https://gitlab.com/snippets/1901490) folder structure. The summary and description must be included and images, icon, and changelog should also be provided for better user experience. The `en-US` locale must be included. — `fastlane/metadata/android/en-US/` contains short/full description, icon, five phone screenshots and `changelogs/5.txt`.

### Docs

* [x] Please read [the guide](https://gitlab.com/fdroid/fdroiddata/-/blob/master/CONTRIBUTING.md) first if this is your first contribution.
* [x] Please make sure your metadata follows the best practice in [our templates](https://gitlab.com/fdroid/fdroiddata/tree/master/templates).
* [x] Please read the [Build Metadata Reference](https://f-droid.org/docs/Build_Metadata_Reference/) and make sure your metadata is valid.
* [x] Please read the [Quick Start Guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/).

### Merge Request Setup

* [x] The title of this merge request should follow "New app: app name" format. — Title: `New app: LRDP`.
* [x] Please make sure your fdroiddata fork is public and your branch is not protected. See <https://docs.gitlab.com/user/project/repository/branches/protected/>.
* [x] Please read [our Git guide](https://gitlab.com/fdroid/wiki/-/wikis/Tips-for-fdroiddata-contributors/Git-Usage) if you don't know how to rebase your branch. Don't rebase your branch if there is no conflict.
* [x] All related [fdroiddata](https://gitlab.com/fdroid/fdroiddata/issues) and [RFP issues](https://gitlab.com/fdroid/rfp/issues) have been referenced in this merge request — no related issues; this MR does not close an RFP issue.
* [x] Please only submit one app in one MR.

### Metadata

* [x] Metadata must be put in `metadata/<applicationId>.yml`. — `metadata/dev.lrdp.lrdp.yml`.
* [x] Metadata must be a valid YAML file.
* [x] Metadata must use LF as line ending.
* [x] Don't add summary/description/changelog/images or anything that should be provided in upstream repo. Please check the Changes tab to make sure there is no other unrelated files added in the MR. — The MR only adds `metadata/dev.lrdp.lrdp.yml` and `metadata/dev.lrdp.lrdp/en-US/summary.txt`.
* [x] Releases are tagged and auto update is enabled unless there is a special reason. — Releases are tagged (`v0.2.0-preview.1`). `UpdateCheckMode: Tags` with `UpdateCheckData` from `pubspec.yaml` reports new versions; `AutoUpdateMode: None` because the custom native build steps (per-ABI OpenSSL/FFmpeg builds) cannot be safely automated by the `Version` mode. Version bumps are handled in metadata MRs.
* [x] There is an issue tracker and contact info of the author so that we can report bugs and contact the author. — GitHub Issues and author email are in the metadata (`IssueTracker`, `AuthorEmail`).
* [x] An AuthorName must be added. It doesn't need to be the real name. — `lucinhu`.
* [x] External repos are added as git submodules instead of srclibs. You can update git submodules without opening an MR in this repo and the submodule is covered by our scanner. — FreeRDP is a git submodule (pinned commit). Flutter is a prebuilt SDK and OpenSSL is a build-time dependency; both are pinned through fdroiddata's `srclibs` (`flutter@3.47.7`, `OpenSSL@openssl-3.5.9`) because they are not app source and are not vendored in the repository.
* [ ] Enable [Reproducible Builds](https://f-droid.org/docs/Reproducible_Builds). We'll use your signature for improved security/reliability, also allowing users to switch between different channels. Do note that if you don't enable reproducible build then the apk will be signed with our key so you can't enable it later. If you can't enable this, please add the reasons here. — Not enabled in this MR: the build depends on the Flutter SDK/Gradle toolchain and generated localization/AOT artifacts that are not bit-reproducible across environments, and the app is built from source in CI. The app is Apache-2.0 and can be built locally; enabling reproducible builds is planned but not yet verified.
* [ ] Setup abi split if the APK is large and the splitted ones can be much smaller. — The current build is a single universal APK with two ABIs (arm64-v8a + x86_64). ABI split will be evaluated before the resubmission if the universal APK is considered too large.
* [x] Only the latest versions should be kept in the metadata before it's merged. If you update the metadata, please replace the old versions with the new ones. — Single build entry, versionCode 5.
* [x] Don't add any disabled versions in the metadata.
* [x] The `commit` field should be the full hash. Please don't use tag or branch in commit. — `98b86ecfc7bb84b1a05d4185714b58bfdd3574d3`.

### Pipeline

* [x] All pipelines should pass. — Pipeline `2981918553` (fork `lucinhu/fdroiddata`, ref `dev.lrdp.lrdp`) is green, including `check apk`.
* [x] All warnings and errors in the Reports tab should be fixed or explained. — `fdroid lint` is clean for this app; the only scanner warnings are in the upstream FreeRDP `test/` fixtures (no fatal problems).
* [x] F-Droid CI runners are under GitLab's FOSS program, so there's no need for you to pay for any CI time. If Gitlab starts asking for phone numbers or credit cards don't submit anything, just leave a note in the MR so we know we need to trigger the CI. — Not applicable.

/label ~"New App"
