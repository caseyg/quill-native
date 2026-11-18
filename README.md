# Quill Native

Native Micropub clients. Sign in with your own website and post to it. Based on the features of [Aaron Parecki’s Quill](https://github.com/aaronpk/Quill).

| Folder | What | Status |
|---|---|---|
| [`ios/`](ios/) | iPhone and iPad app (SwiftUI), its share extension, and the `QuillCore` Swift package | In use |
| [`android/`](android/) | Android app (Kotlin, Jetpack Compose) and its `core` Kotlin library | Early scaffold |
| [`docs/`](docs/) | Website at [caseyg.github.io/quill-native](https://caseyg.github.io/quill-native/), also the IndieAuth client ID page | Live |

Both apps talk to the same Micropub, IndieAuth and GitHub APIs and should send the same requests. When a request changes in one, change the other to match. `QuillCore` on iOS is the reference.

The website stays in `docs/` because GitHub Pages serves it from `main`, folder `/docs`.

## Build

- iOS: see [ios/README.md](ios/README.md). In short, open `ios/QuillNative.xcodeproj`.
- Android: see [android/README.md](android/README.md). In short, open `android/` in Android Studio, or run `./gradlew :app:assembleDebug` there.

## License and credits

Quill Native is licensed under the [Apache License 2.0](LICENSE). See [`NOTICE`](NOTICE).

It is modelled on [Quill](https://github.com/aaronpk/Quill), Copyright 2013-2016 Aaron Parecki and contributors, also Apache License 2.0. These apps are new native implementations of compatible Micropub requests and contain no code or assets copied from Quill.

If you ever bring in code from Quill, keep its copyright line, add a note at the top of the file saying it was modified and how, and keep the credit in `NOTICE`. Apache 2.0 requires all three.
