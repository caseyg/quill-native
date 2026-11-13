# Quill Native

A SwiftUI Micropub client for iPhone and iPad, based on the functionality of [Aaron Parecki’s Quill](https://github.com/aaronpk/Quill). iOS 17 or later. Native-only: email/MMS ingestion is intentionally excluded.

## Run

1. Open `QuillNative.xcodeproj` in Xcode.
2. Select the `QuillNative` scheme and an iPhone or iPad Simulator, then Run.
3. For a physical device, copy `Config/Signing.local.example.xcconfig` to `Config/Signing.local.xcconfig` and set your team ID, or choose your signing team in Xcode for the app, share extension, and tests. Register your own bundle IDs and App Group, and update `SharedStorage.group` and both entitlement files together. No third-party SDKs or package downloads are needed.

The checked-in project can be regenerated with `python3 scripts/generate_project.py` after adding source files. The generator uses only Python’s standard library.

## Connect a website

Use Settings to sign in through IndieAuth, or connect a personal Micropub token. Tokens are stored in this device’s Keychain and are never placed in shared defaults or draft files. The share extension saves drafts; it does not need or receive the token.

For IndieAuth, enter a full website URL including `https://` and a full HTTPS IndieAuth client-ID URL, then tap **Login**. The client ID is prefilled with `https://caseyagollan.com/clients/quill-native/` and remains editable. The website's sign-in endpoints are discovered when you log in.

The prefilled client ID comes from `QuillIndieAuthClientID` in `Config/App-Info.plist`. Its public page must declare `quill-native://oauth` with `rel="redirect_uri"`; `Config/client.html` is an example. The app validates OAuth state, PKCE, and the discovered issuer. It requests create/update/media and negotiates draft scope when advertised.

For personal tokens, enter your site URL, paste the token into the secure field, and enter the scopes actually granted by your site. These scopes are user-supplied information; the server remains the authority on permissions. The app tests the token with a capability query before saving it.

## Features

- Notes, photos, replies and RSVPs, articles, bookmarks, likes, reposts, events, reviews, itineraries, code snippets, weight, and exercise.
- Native article formatting, HTML source, preview, links, and photos. Attached article photos are included after the text when publishing.
- Tags, slug, published time, server-side scheduling and remote drafts, visibility, channels, syndication, configurable legacy field names, HTML representation, and weight units.
- Media endpoint upload, multipart fallback, photo descriptions, camera/Photos picker, recent uploaded media, optional location/map, and place lookup for travel legs.
- Edit existing likes, reposts and code snippets by URL, matching upstream’s implemented edit interfaces.
- Atomic local drafts with photo data, search, resume, publication receipts, and sharing of resulting links.
- A share extension that saves text, URLs and images as local drafts.
- App Shortcuts: **Compose a note**, **Bookmark a URL**, **Resume a draft**. These open a composer and never publish automatically.
- Deep links, for example `quill-native://reply?reply=https%3A%2F%2Fexample.com%2Fpost` or `quill-native://note?text=Hello`.

A future publication time is a request to the Micropub server, not an iOS background alarm. Visibility and remote draft behavior likewise depend on server support. An HTTP success without a valid `Location` is reported as ambiguous: check your site before manually retrying. Drafts are retained on errors.

## Test

Core protocol and persistence tests:

```sh
swift test --package-path QuillCore
```

Simulator tests use the `QuillNative` scheme. For the local publication test, first start the fixture server:

```sh
python3 scripts/fixture_server.py
```

Then run the scheme’s tests in Xcode. The server binds only to `127.0.0.1:8765`, accepts only the synthetic `fixture-token`, and records requests at `/private/tmp/quill-fixture-requests.jsonl`. Debug-only `--fixture` and `--route URL` launch arguments support deterministic tests. Release builds do not accept these testing arguments.

[Design and parity scope](docs/design.md) · [Verification record](docs/parity.md)

## Attribution

Quill is by Aaron Parecki and contributors, under Apache License 2.0. This project independently implements native interfaces and compatible protocol payloads. See `NOTICE` and `LICENSE` for attribution and license terms.

## Device installation

`Config/Signing.local.xcconfig` is ignored by Git. Before the first device install, register/check your App Group in **Signing & Capabilities → App Groups** for both `QuillNative` and `QuillShare`. Automatic profiles must authorize that group. The generator declares the capability and enables `REGISTER_APP_GROUPS`.

After signing is configured and the phone is paired/unlocked, rebuild and install with:

```sh
./scripts/install_on_device.sh YOUR_DEVICE_ID
```

A no-cost Personal Team provisioning profile expires after seven days; rerun the script to refresh the installation. The app’s existing on-device drafts and Keychain sign-in are retained by a normal update.

## Credentials and local data

Access tokens are stored in the device Keychain. Drafts and attachments live in the app's local App Group container. This repository does not include device data, credentials, provisioning profiles, signing keys, or local signing-team settings. The `fixture-token` and `secret` strings in tests are synthetic fixtures. The public IndieAuth client-ID URL identifies the app; it is not a credential.
