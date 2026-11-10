# Kyokai for Android

Kyokai for Android controls your computers from an Android phone, tablet or
foldable, as [Kyokai](https://github.com/YuanZhe-99/Kyokai) does from a
desktop. It is a controller only: nobody connects to the phone.

It uses Kyokai Core, the same Rust core as the desktop app, so it joins
the same EasyTier networks, signs in with the same passwords and keys, and
talks to any Kyokai host of a compatible version.

## What it does

- **Desktops**: the host's screen in H.264 or HEVC, decoded in hardware;
  touch, an on-screen touchpad, a full keyboard with modifier keys, a
  hardware keyboard and mouse; sound; several displays; quality and size
  choices; session actions (lock, Ctrl+Alt+Del, block input, privacy
  screen, wake the screen).
- **Foldables**: two panes when unfolded, and a laptop mode at a half-folded
  hinge (the screen above, keyboard and touchpad below).
- **Clipboard**: text and images both ways, and a history of what crossed.
- **The host's AI**: start tasks, reply, approve or decline its actions,
  and see the tasks it showed while you were connected.
- **SSH, Remote Desktop and VNC** of the host itself, through Kyokai
  tunnels; **SFTP** files over SSH, with upload and download.
- **NanoKVM USB**: the computer wired to a host's NanoKVM.
- **Wake**: turns a host's screen back on, from the device list too.
- **Networks**: up to eight EasyTier networks, direct paths, routes by
  address.

The phone's version and the Kyokai Core version it carries are in
Settings → About.

## Install

Download `Kyokai-Android-<version>-arm64.apk` from
[Releases](https://github.com/YuanZhe-99/Kyokai-Mobile/releases) and check it
against its `.sha256`. Android 8.0 or later, 64-bit ARM.

How to use it: [doc/user-guide.md](doc/user-guide.md)
([中文](doc/user-guide.zh.md)).

## Build

Needs Flutter (see `FLUTTER_VERSION` in `.github/workflows/ci.yml`), the
Android SDK and NDK, the Rust toolchain that `third_party/kyokai` pins with
the `aarch64-linux-android` target, Go, and Git submodules:

```bash
git submodule update --init --recursive
bash tool/build_core.sh      # Kyokai Core (Rust): libkyokai_core.so
bash tool/build_clients.sh   # SSH, RDP, VNC, SFTP (Go): libkyokai_clients.so
bash tool/build_apk.sh       # the arm64 APK
```

`tool/build_apk.sh` signs with `android/key.properties` when it exists,
else with the debug key. CI (`.github/workflows/ci.yml`) runs the checks
and tests on every push, builds the APK, and publishes a release for a
`v*` tag that matches `pubspec.yaml`.

Developer notes: `doc/dev/` (the core's control, media and services APIs,
and `progress.md`).

## License

GNU Affero General Public License, version 3 ([LICENSE](LICENSE)). The
native libraries and what they include are listed in Settings → About →
License.
