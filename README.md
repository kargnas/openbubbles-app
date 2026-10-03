# OpenBubbles

OpenBubbles is an open-source and cross-platform ecosystem of apps aimed to bring Apple platform services to Android and Windows! With OpenBubbles, you'll be able to send messages, media, and much more to your friends and family.

**Please note that OpenBubbles requires access to a Mac and an Apple ID to function!

Key Features:

- Send/receive emoji reactions 
- Send formatted messages (bold, italic, etc)
- Edit messages
- Unsend messages 
- Call your friends on FaceTime
- Answer calls from your friends on FaceTime
- See friends' locations on FindMy
- Join and Sync iCloud Shared Albums
- See typing indicators
- Receive stickers
- Create and manage group chats
- Add an icon to personalize your group chat 
- Send images and videos
- Forward SMS and MMS to/from connected Macs or other devices with OpenBubbles 

If you need help setting up the app, have any issues or feature requests, or just want to come hang out, feel free to join our Discord, linked below! We hope you enjoy using the app!

## Useful links

* Our Website: [here](https://openbubbles.app)
* Discord: [here](https://discord.gg/98fWS4AQqN)!
    - We highly encourage users to join to get in direct communication with the developers and community
* GitHub: [here](https://github.com/OpenBubbles)
    - Please submit any issues with the app here so we can properly track them! Remember to search before opening a ticket :)

## Getting Started

[Quickstart](https://openbubbles.app/quickstart.html)

## Building the Alpha APK (this fork)

The default build path is an Apple Silicon Mac; GitHub Actions is the fallback/CI build.

```sh
scripts/build-alpha-mac.sh                  # build build/app/outputs/flutter-apk/app-alpha-debug.apk
scripts/build-alpha-mac.sh --install        # build, then adb install -r (never uninstalls)
scripts/build-alpha-mac.sh --install SERIAL # same, for a specific adb device
```

Prerequisites: Flutter 3.24.0 (via [fvm](https://fvm.app), pinned in `.fvmrc`, or `flutter` on PATH), rustup with the stable toolchain, `protoc` (`brew install protobuf`), Java 21 (`brew install openjdk@21`) and the Android SDK (`ANDROID_HOME`, default `~/Library/Android/sdk`) with `cmdline-tools/latest`, so cargokit can install NDK 26.1.10909125 through `sdkmanager` (or install it yourself: `sdkmanager "ndk;26.1.10909125"`). If a Homebrew `rust` formula is also installed, the script puts rustup's `rustc` first on PATH. A warm build takes about 5 minutes on an M4 MacBook Pro. The script initialises submodules over HTTPS and creates the fake Fairplay certs.

**Signing.** Alpha builds are signed with a fixed key so new builds install over the old one. The key lives outside the repo in `~/keys/openbubbles-alpha/` with a `key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`; `storeFile` may be relative to that directory). Backups of the key exist outside the repo. Gradle can also take the key from `ALPHA_KEYSTORE_FILE` / `ALPHA_KEYSTORE_PASSWORD` / `ALPHA_KEY_ALIAS` / `ALPHA_KEY_PASSWORD`, or from a `key.properties` at `ALPHA_KEY_PROPERTIES`. Without a key it falls back to the default debug key (the script refuses unless `ALLOW_DEBUG_KEY=1`).

In GitHub Actions, set the secrets `ALPHA_KEYSTORE_BASE64` (base64 of the keystore), `ALPHA_KEYSTORE_PASSWORD`, `ALPHA_KEY_ALIAS` and `ALPHA_KEY_PASSWORD`. Without them (e.g. PRs from forks) CI builds with the debug key. The build log prints the signer SHA-256.

The Alpha package `com.bluebubbles.messaging.alpha` installs side by side with the Play Store app `com.openbubbles.messaging`.

> **Warning:** if the Alpha key is lost, the installed Alpha cannot be updated. It has to be uninstalled and reinstalled, which loses its data: Apple sign-in and iMessage registration must be redone.
