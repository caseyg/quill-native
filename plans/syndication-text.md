# Syndication text for each network

Status: built in Quill (#15). Servers need one small change to use the text. Until they have it, they ignore the text and write their own.

## What Quill does

From a published post, **Syndicate…** opens a sheet:

- Chips for each syndication target the post isn't on yet. All of them start chosen.
- One shared text for every chosen network, which starts from the post's title and text, shortened to fit Bluesky's 300 characters, followed by a link back. **Edit Separately** gives each network its own text, and **Use One Text** joins them again. This matches the syndicate page on caseyagollan.com.
- Each network counts characters its own way. Bluesky counts graphemes. Mastodon counts every link as 23 and `@user@host` as `@user`. A shared text shows the count of whichever network is closest to its limit.
- Typing `@` suggests people you follow on that network. In a shared text it suggests from the first chosen network. Follows are read from the public Bluesky and Mastodon APIs, cached on the device, and refreshed at most once a day.
- **Post** sends one Micropub update:

```json
{
  "action": "update",
  "url": "https://example.com/2026/11/17/post/",
  "mp-syndicate-to": ["https://example.com/syndication/bluesky", "https://example.com/syndication/mastodon"],
  "mp-syndicate-text": {
    "https://example.com/syndication/bluesky": "Text for Bluesky…\n\nhttps://example.com/2026/11/17/post/",
    "https://example.com/syndication/mastodon": "Text for Mastodon…\n\nhttps://example.com/2026/11/17/post/"
  }
}
```

`mp-syndicate-to` goes at the top level, beside `action`, which is where caseyagollan.com reads it. The field name follows Settings → Syndication Field. `mp-syndicate-text` is keyed by target `uid`, and each value is the exact text to post, link included.

### Whose account

Quill needs to know your account on each network to read your follows. It looks, in order, at:

1. The target's `user.url` in `q=config`, as Micropub's syndicate-to extension describes: `{"uid": "…", "name": "Bluesky", "service": {"name": "Bluesky"}, "user": {"url": "https://bsky.app/profile/example.com"}}`.
2. The account that most of your posts' `syndication` links point to, such as `bsky.app/profile/<handle>/post/…` or `https://<instance>/@<user>/…`.

If neither turns anything up, there are no suggestions, and you can type a full handle.

## Server change for caseyagollan.com

These are the changes in `src/lib/server/publishing/micropub.ts`, in the update branch:

1. Read `input['mp-syndicate-text']`. Refuse it with 400 unless it's an object whose keys are advertised target uids and whose values are strings of 10,000 characters or fewer.
2. If it's present, don't only add `syndicationTargets` and queue the send. Send right away through the same path as the web syndicate page, so the texts are used, receipts are shared, and links are written back to GitHub:

   ```ts
   const drafts = Object.fromEntries(Object.entries(texts).map(([uid, text]) => [uid.endsWith('/mastodon') ? 'mastodon' : 'bluesky', text]));
   const message = await sendEditorDrafts(config, post, await publicationRevision(post), Object.keys(drafts), drafts, { gitFetch: fetch });
   ```

   `sendEditorDrafts` already checks each text against the network's limit with `syndicationText`, so an empty or too-long text returns 422 before anything is posted.
3. Optionally, add `service` and `user` to each `syndicationTargets(config)` entry, so Quill doesn't have to infer your account from your posts:
   - Bluesky: `user.url` is `https://bsky.app/profile/<PUBLISHING_BLUESKY_IDENTIFIER>`.
   - Mastodon: `user.url` is `<PUBLISHING_MASTODON_INSTANCE>/@<MASTODON_ACCOUNT>`.

Right now, `mp-syndicate-to` on an update makes caseyagollan.com syndicate with its own text, and `mp-syndicate-text` is ignored, since it sits at the top level and not in `properties`.

## Later

- Per-network text in the composer, when a post is first created. The post's URL isn't known yet, so the server would have to add the link, or the post would need to be sent first and then syndicated. Threads are planned separately in `syndication-threads.md`.
- Resolving Bluesky handles to DIDs for mention facets is the server's job. caseyagollan.com already does it in `syndicate()`.
