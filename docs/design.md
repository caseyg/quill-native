# Quill Native design

Implementation scope, 2026-11-13.

## Goal and boundary

Build a native SwiftUI iPhone/iPad Micropub client with functional parity with aaronpk/Quill, adapting browser interactions to iOS. Native-only; email/MMS ingestion and its Mailgun backend are excluded. No Quill server is required.

Reference reviewed: https://github.com/aaronpk/Quill at commit 3cabff0c599439864fe82f6d923c11c7a69aa58b. Inventory comes from controllers/controllers.php, controllers/auth.php, controllers/editor.php, controllers/micropub.php, views/dashboard.php, views/settings.php and the individual editor views. The README alone does not describe the full feature set.

## Native experience

- Compose tab: accessible post-type picker and focused native editors. Frequent actions are notes, photos, replies, bookmarks, likes, and reposts; all remaining types stay directly available.
- Drafts tab: automatically saved local work, explicit resume and delete, and attachment preservation across launches. Sending a remote draft is a separate explicit action.
- Activity tab: local publication receipts with resulting URL, retryable failures, and an edit-by-URL entry point. This is not presented as a complete server timeline.
- Settings tab: account, endpoint/capability diagnostics, token revocation/sign out, defaults, and legacy Micropub field mappings.
- Native navigation, sheets, date pickers, Photos picker, camera where available, Core Location, MapKit previews, share extension, Dynamic Type, VoiceOver, light/dark mode, and adaptive iPad layout.

## Parity checklist

| Area | Required behavior |
| --- | --- |
| Authentication | Normalize site URL; discover authorization, token and Micropub endpoints from HTML rel links and HTTP Link headers; use ASWebAuthenticationSession; validate state and callback; use PKCE where supported; store tokens in Keychain; report granted scope; revoke/reset account |
| Capabilities | Query Micropub configuration, supported post types, media endpoint, syndication targets, channels and visibility; refresh; gracefully handle unsupported optional queries |
| Notes/photos | Plain content, photo attachments and descriptions, reply URL and context, RSVP, tags, slug, published date/time, location/map, visibility, syndication; preserve draft on failure |
| Article | Title and rich content with native editing/preview, links and images; HTML content representation preference; tags, slug, remote draft status and server-side scheduling via published date |
| Bookmark/like/repost | Target URL; bookmark title, description, tags and syndication; source loading and updates for likes/reposts, matching upstream's supported edit behavior |
| Event | h-event name, start/end with time zones, content, location/place details, tags, channel and content type; conference, slides and video URL/embed metadata |
| Review | h-review item metadata, name/content, rating and bounds, tags and publication time |
| Itinerary | Repeatable h-leg objects with transit type, operator, number, origin/destination, departure/arrival and independent time zones; airport lookup and tags |
| Code | Title, source, language, filename and content encoding matching upstream's code publishing request |
| Weight | h-measure number and configured unit with publication time |
| Exercise | h-workout activity, duration in seconds, heart rate in bpm and publication time |
| Media | Media endpoint uploads and multipart fallback when absent; image orientation/metadata handling; readable upload errors and retry; restore attachments from local drafts |
| Compatibility | Configurable slug and syndication field names, HTML representation, weight unit and preferences; JSON and form/multipart requests as required |
| External entry | Share extension for text, URLs and images; URL schemes supporting compose/reply/target prefills as native equivalents to bookmarklets and GET parameters |
| App Intents | Compose note, bookmark URL, resume draft; small post-type AppEnum and draft AppEntity; one routing handoff into app; discoverable App Shortcuts; no automatic publication when merely opening a composer |

All source properties, nested microformats and legacy keys will be checked against upstream during implementation. Optional endpoint capabilities must not appear as verified server support when absent. Private posts must not retain syndication selections that could disclose them.

## Architecture

Minimum deployment target: iOS 17. SwiftUI and Observation for app state; a Foundation-based Swift package for models, discovery, Micropub serialization, validation and networking; SwiftData or atomic Codable storage for local drafts/receipts; files for attachments; Keychain for secrets. The app and share extension share drafts and preferences through an App Group. Credentials stay in the main app’s Keychain and are not shared with the extension. Provisioning identifiers are documented for device signing.

The protocol layer accepts an injected URLSession/transport so fixture tests verify discovery, requests and errors without posting to a real site. A development-only fixture server supports Simulator end-to-end testing. The UI always distinguishes local save, remote draft, scheduled publication and publication success. Successful posts require a valid HTTP response and usable publication receipt; a network failure never clears local work or silently retries a potentially completed create.

Scheduling is delegated to a capable Micropub server. Background execution on iOS is not a reliable exact-time publisher. Reply context and airport lookup use documented public services or configured providers, with manual entry available when a lookup fails. No private service keys ship in the binary.

## Verification and completion gates

1. Protocol fixture tests: rel discovery and relative URLs; auth state rejection; JSON/form/multipart payloads; all nested post types; configuration parsing; error and Location-header handling; update payloads; secret redaction.
2. Persistence tests: drafts and attachments survive relaunch; failed sends retain work; share/intent handoff preserves content.
3. Build application, share extension, and App Intents with Xcode; run tests on an iOS Simulator.
4. Simulator interaction checks for every composer, validation, save/resume, Photos, settings, accessibility and error recovery; fixture-server create/upload/edit checks.
5. Live IndieAuth and publish/upload/edit checks require an account and explicit authorization to create test posts. Fixture success is not proof of live endpoint compatibility.
6. Record completed and outstanding parity items with evidence; do not describe the app as fully verified while any required flow remains untested.

## Development and verification

See [README](../README.md) for setup and [parity and verification](parity.md) for completed checks and remaining limits.
