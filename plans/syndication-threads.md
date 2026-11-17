# Plan: threads for Bluesky and Mastodon

Status: planned, not built. Needs a matching change on the Micropub server.

## Goal

A long post can go out to Bluesky and Mastodon as a thread instead of a single post that gets cut off. Quill suggests where to split it. You can edit each part before sending, and edit the thread again later.

## Who does what

The **server** keeps doing the posting. It already owns the Bluesky and Mastodon credentials and the POSSE logic, and it records the `syndication` links. Quill never signs in to those services.

**Quill** writes the thread and sends it as extra Micropub properties. Micropub has no standard way to send a thread, so these properties are a convention between Quill and servers that opt in. A server that doesn't know them ignores them, and the post syndicates as it does now.

## Protocol

### 1. The server advertises support

The server lists threading limits on each entry in `syndicate-to`, from `q=config` or `q=syndicate-to`:

```json
{
  "syndicate-to": [
    {
      "uid": "https://bsky.app/profile/example.com",
      "name": "Bluesky",
      "x-thread": { "max-length": 300, "count": "graphemes", "link-length": null, "max-parts": 25 }
    },
    {
      "uid": "https://mastodon.social/@example",
      "name": "Mastodon",
      "x-thread": { "max-length": 500, "count": "characters", "link-length": 23, "max-parts": 25 }
    }
  ]
}
```

- `max-length`: the most each part can hold.
- `count`: how the service counts. Bluesky counts graphemes. Mastodon counts characters, and every URL counts as `link-length`.
- `link-length`: a fixed length for every URL, or `null` to count URLs as written.
- `max-parts`: the longest thread the server will post.

Quill offers the thread editor only for targets that have `x-thread`.

### 2. Quill sends the thread with the post

There's one new server command property, `mp-thread`. It's an object keyed by target `uid`, and each value is the list of parts in order:

```json
{
  "type": ["h-entry"],
  "properties": {
    "content": ["The full post…"],
    "mp-syndicate-to": ["https://bsky.app/profile/example.com", "https://mastodon.social/@example"],
    "mp-thread": [{
      "https://bsky.app/profile/example.com": ["Part one…", "Part two…", "Part three…"],
      "https://mastodon.social/@example": ["Part one…", "Part two…"]
    }]
  }
}
```

- `mp-` marks this as an instruction to the server, not a property to publish. It's wrapped in an array like every other Micropub property.
- A target that's in `mp-syndicate-to` but missing from `mp-thread` syndicates the way it does today.
- The parts are the exact text to post. Quill already adds a link back to the canonical post when the person wants one, so the server doesn't add another.
- Threads need JSON requests. Quill already sends JSON unless photos have to go up as multipart because the site has no media endpoint. In that case the thread editor is turned off, or the photos are uploaded first.

The same property works on an existing post, through the Syndicate menu (#15):

```json
{
  "action": "update",
  "url": "https://example.com/2026/11/post",
  "add": { "mp-syndicate-to": ["https://bsky.app/profile/example.com"] },
  "mp-thread": [{ "https://bsky.app/profile/example.com": ["Part one…", "Part two…"] }]
}
```

### 3. The server reports back

- Add the URL of the thread's **first** part to `syndication`, which is the link Quill opens with "Open on Bluesky".
- Store the thread so it can be edited later, as `x-thread` on the post: `{ uid: [{ "text": "…", "url": "…" }] }`. It comes back from `q=source`, so Quill can reopen the editor on what was actually posted.

### 4. Editing a thread that's already out

Quill sends an update with a new `mp-thread` for that target. The server handles each service:

- **Mastodon** can edit statuses (`PUT /api/v1/statuses/:id`). Edit the parts that changed. If parts were added, reply to the last one. If parts were removed, delete them from the end.
- **Bluesky** can't edit posts. Parts whose text didn't change stay. Every part from the first changed one onwards is deleted and posted again as replies to the last part that was kept. If the first part changes, the whole thread is replaced and `syndication` gets the new first URL. Quill warns about this before sending: "Replaces the thread on Bluesky. Replies and likes on the old posts stay with them."

## Server changes

For the person who runs the site, such as an Indiekit plugin or a custom endpoint:

1. Add `x-thread` limits to the `syndicate-to` entries.
2. Read `mp-thread` on create and update. Check each part against the limits, and refuse the request with HTTP 400 and a clear `error_description` if a part is too long or there are too many parts, rather than cutting text.
3. Post the parts as a reply chain:
   - Bluesky: `com.atproto.repo.createRecord` for each part, with `reply.root` set to the first part and `reply.parent` set to the one before it, plus link facets for URLs.
   - Mastodon: `POST /api/v1/statuses` with `in_reply_to_id` set to the previous part. Use the same visibility for every part (often `unlisted` after the first, if the person prefers).
4. Record the first part's URL in `syndication` and the whole thread in `x-thread`.
5. Handle editing as described above.
6. Ignore `mp-thread` for targets it doesn't support.

## Quill changes

### Model (QuillCore)

- `SyndicationTarget.thread: ThreadLimits?`, parsed from `x-thread`.
- `Draft.threads: [String: [String]]?`, keyed by target uid. It's optional so drafts saved before this still load. It's included in the GitHub draft export front matter.
- `Post.threads`, read from `x-thread` in `q=source`, for editing later.
- `ThreadSplitter.split(text, limits) -> [String]`. It splits at paragraphs first, then sentences, then words, and only splits a word if it has to. It counts the way the target does (graphemes or characters, with fixed-length links). It never splits inside a URL, and it keeps Markdown links whole by sending their plain-text form. Optional "1/3" numbering takes up room in each part's count.
- `Payload` adds `mp-thread` for targets that have parts, both on create and in the syndicate update.
- Tests cover the splitter (limits, URLs, emoji, CJK, empty paragraphs), payloads, and old drafts loading.

### Editor (app)

- In the composer's syndication chips, a target with `x-thread` whose text is over its limit shows a part count, such as "Bluesky · 3". Tapping it opens the thread editor.
- The thread editor is a sheet with one tab per target, using the system segmented control. Each part is its own text field with a remaining-character count that turns red past the limit.
  - Split at the cursor, merge with the part above, and delete, from a context menu on each part.
  - **Reset** splits the text again from the post.
  - A toggle for "1/n" numbering, remembered for each target.
- Once you edit the parts, they stay as you left them. Editing the post afterwards marks the thread "Out of date" and offers Reset, rather than overwriting your edits.
- The Syndicate menu on a published post opens the same editor before sending, when the target supports threads and the post is long.
- "Edit Thread on Bluesky" in a post's context menu reopens the editor from `x-thread`, with the Bluesky warning above.

### Out of scope for the first version

- Choosing which photos go with which part. The first part gets the post's photos, up to each service's limit of four.
- Alt text per part beyond what the photos already carry.
- Threads for targets other than Bluesky and Mastodon. The protocol is generic, so any target can opt in.

## Order of work

1. Server: `x-thread` in config, plus `mp-thread` on create. This is enough to test with curl.
2. Quill: model, splitter, payload and tests.
3. Quill: the thread editor in the composer.
4. Server and Quill: threads through the Syndicate menu on existing posts.
5. Server and Quill: editing threads that are already out.
