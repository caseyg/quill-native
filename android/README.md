# Quill Native for Android

The Android version of Quill, built to match the iOS app feature for feature:

- Sign in with your website through IndieAuth in the browser, or with an access token. Tokens are encrypted with an Android Keystore key.
- Every post type the iOS app has: notes, photos, replies, articles (Markdown styled as you type, or rich HTML), bookmarks, likes, reposts, code, events, reviews, itineraries, weight and exercise.
- Photos from the library or camera with descriptions, the media endpoint, location, tags, slug, date, visibility, channels, drafts on the server, syndication targets, and a view of the request body.
- Drafts kept on the device. Posts sync to the device for browsing, search, editing and deleting.
- Voice notes transcribed while you speak. Keeping the recording too needs Android 13 or later to transcribe at the same time.
- Drafts on GitHub, with device-flow sign-in or a token.
- A share sheet for links, text and images, launcher shortcuts for a new note, a voice note and recent drafts, and the same `quill-native://` links as iOS.

## Layout

- `core/`: plain Kotlin with no Android dependencies, ported from the iOS `QuillCore` package. Models, payloads, the Micropub client, the post library and feeds, IndieAuth, GitHub drafts and Markdown styling. Unit tests run on any JVM.
- `app/`: the Android app. Jetpack Compose with Material 3, using the wallpaper's colors on Android 12 and later. Minimum Android 8.0 (API 26).

## Build

Open this folder in Android Studio, or from the command line with JDK 17 and the Android SDK installed:

```sh
./gradlew :core:test          # unit tests, no Android SDK needed
./gradlew :app:assembleDebug  # app/build/outputs/apk/debug/
./gradlew :app:installDebug   # onto a connected device or emulator
```

CI runs both on every pull request that touches `android/` and uploads the debug APK.

The IndieAuth client ID and the GitHub OAuth client ID default to the same values as iOS. Override them with `-PquillClientId=…` and `-PquillGitHubClientId=…` (an empty GitHub ID leaves token sign-in only).

## Differences from iOS

- Locations show coordinates with a link to the maps app instead of an inline map, and itinerary legs have no place search.
- Dates keep the time zone they were written in, or use the device's. There is no time zone picker.
- The rich HTML editor is a WebView, so the HTML it saves is the browser's own.
- Voice recordings are attached as WAV.

## Credits

Licensed under the [Apache License 2.0](../LICENSE). Modelled on [Quill](https://github.com/aaronpk/Quill), Copyright 2013-2016 Aaron Parecki and contributors, also Apache License 2.0. This is a new native implementation and contains no code or assets copied from Quill. See [`NOTICE`](../NOTICE).
