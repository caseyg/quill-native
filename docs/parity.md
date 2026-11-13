# Parity and verification

Reference: [aaronpk/Quill](https://github.com/aaronpk/Quill), commit `3cabff0c599439864fe82f6d923c11c7a69aa58b`. Last verified November 13, 2026.

## Native scope

| Capability | Implementation and limits |
| --- | --- |
| Publishing | Notes, photos, replies/RSVPs, articles, bookmarks, likes, reposts, events, reviews, itineraries, code, weight and exercise |
| Articles | Native formatting, HTML source, preview, links; attached images publish after the text |
| Media | Photos/camera, media endpoint uploads, multipart fallback, descriptions and recent-upload lookup |
| Location and travel | Core Location, MapKit previews/place search, manual time zones; replaces upstream's browser/third-party lookup services |
| Post options | Tags, slug, published time, remote draft requests, visibility, channels, syndication and compatibility field mappings |
| Editing | Source queries and updates for likes, reposts and code, matching upstream's implemented editing interfaces |
| Authentication | Full website/client-ID URLs, endpoint discovery on Login, system-browser IndieAuth, PKCE/state/issuer checks, Keychain and token revocation; personal-token fallback |
| Drafts | Atomic local persistence including attachments, search and resume; retained on failure |
| System integration | Share extension, URL prefills, compose-note/bookmark/resume-draft App Intents and shortcuts |
| Email/MMS | Excluded from this native-only implementation |

Remote visibility, drafts and scheduling depend on the Micropub server. A missing publication Location header is reported as ambiguous and does not automatically retry the create request.

## Verification evidence

- Complete core package suite: **34 tests passed**. Covers discovery, URL requirements, OAuth callback validation, scope negotiation, payload vocabularies, errors, media, redirects and persistence.
- Complete non-live iPhone UI suite: **8 tests passed** on iOS 18.6 before the final connection-form restoration.
- Final connection-form check: **passed**; Login requires both fully qualified URLs and exposes the editable client-ID field.
- iPad: **2 checks passed**, covering dark layout and draft save/resume.
- Share integration: Safari → Quill extension → persisted URL draft verified in Simulator.
- App Intents: metadata builds; actual compose-note intent/handoff exercised in Simulator.
- Debug and Release Simulator builds passed. Signed physical iPhone build, installation, signature validation and launch passed.
- One explicitly authorized, labeled live note was published and its public content verified. No live credentials are included in the test suite. The live publishing test requires an explicit opt-in environment variable and should never be retried after an ambiguous response.

## Remaining verification

Live browser-consent/token-exchange round trip; live upload/edit and every remote post type; Siri voice invocation; physical camera/location permission paths; larger accessibility text sizes. The app is not yet fully verified against every Quill feature on every server.
