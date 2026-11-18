# Quill Native for Android

Early scaffold. It signs in with a website and an access token, finds the Micropub endpoint, and posts notes. Text shared from other apps opens as a new note.

## Layout

- `core/`: plain Kotlin, no Android dependencies. Endpoint discovery, form encoding and the Micropub client, ported from the iOS `QuillCore` package. Unit tests run on any JVM.
- `app/`: the Android app. Jetpack Compose with Material 3, using the wallpaper's colors on Android 12 and later. Minimum Android 8.0 (API 26).

## Build

Open this folder in Android Studio, or from the command line with JDK 17 and the Android SDK installed:

```sh
./gradlew :core:test          # unit tests, no Android SDK needed
./gradlew :app:assembleDebug  # app/build/outputs/apk/debug/
./gradlew :app:installDebug   # onto a connected device or emulator
```

CI runs both on every pull request that touches `android/` and uploads the debug APK.

## Not yet

Roughly in the order the iOS app has them:

- IndieAuth sign-in through the browser (the `quill-native://oauth` redirect is registered but unused)
- Tokens in the Android Keystore instead of app preferences
- Drafts kept on the device, and the post list from `q=source`
- Other post types, photos and the media endpoint, Markdown articles
- Syndication targets, Drafts on GitHub, voice notes
- A run against `ios/scripts/fixture_server.py` from the emulator, which needs a discovery page on the fixture and a debug-only cleartext exception
