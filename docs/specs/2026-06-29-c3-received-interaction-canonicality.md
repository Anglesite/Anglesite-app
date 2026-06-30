# C.3: Received-Interaction Data Canonicality

**Date:** 2026-06-29
**Status:** Decided
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)
**Prerequisite for:** V-3.4 (#362, render + snapshot received interactions)

---

## The Question

When someone else's site sends a webmention to your site (a reply, a like, a
repost), or when an ActivityPub actor delivers an activity to your inbox, the
Worker's inbox store (D1) records it. That data is **someone else's content,
cached on your infrastructure.** Is it canonical in your git repo (`Source/`)?

This matters because #72 says "git is the source of truth." If received
interactions only live in D1, they're lost when you move hosting providers — your
site's comment section evaporates. If they're in git, they survive any backend
migration.

## Decision

**Snapshot received interactions into `Source/` git.** The Worker periodically
(or on-demand) serializes verified interactions to JSON files in
`Source/data/interactions/`, committed to the site's repo. This is the
IndieWeb-standard approach: your site's git repo contains a complete, portable
record of both your content and the interactions it received.

### The schema

Each interaction is a JSON file at `Source/data/interactions/{id}.json`:

```json
{
  "id": "wm-abc123",
  "type": "webmention",
  "source": "https://other.example/post/42",
  "target": "https://my.site/articles/hello-world",
  "interactionType": "reply",
  "author": {
    "name": "Jane Doe",
    "url": "https://other.example",
    "photo": "https://other.example/photo.jpg"
  },
  "content": "Great post! I especially liked the part about...",
  "published": "2026-06-28T14:30:00Z",
  "verified": "2026-06-28T14:35:12Z",
  "verificationStatus": "verified"
}
```

Fields:
- `id`: Stable, unique ID assigned by the Worker (e.g. `wm-{hash}`, `ap-{hash}`)
- `type`: Protocol source — `"webmention"`, `"activitypub"`, `"micropub"`
- `source`: The URL that sent the interaction
- `target`: The URL on this site that received it
- `interactionType`: `"reply"`, `"like"`, `"repost"`, `"bookmark"`, `"mention"`
- `author`: Parsed h-card / ActivityPub actor (name, url, photo — all optional)
- `content`: Text/HTML content of the interaction (optional, may be truncated)
- `published`: When the source published it (ISO 8601)
- `verified`: When the Worker verified it (ISO 8601)
- `verificationStatus`: `"verified"`, `"pending"`, `"failed"`

### The flow

```
External site → Webmention/AP → Worker inbox (D1)
                                      │
                                      ▼
                              Verify (async queue)
                                      │
                                      ▼
                              Snapshot to git ─────────► Source/data/interactions/
                              (on verify, or periodic)     │
                                                           ▼
                                                    Astro build reads
                                                    interactions → renders
                                                    on the target page
```

### Design principles

1. **Git-canonical, D1-operational.** D1 is the live operational store (fast
   lookup, queue management). Git is the canonical archive. They stay in sync
   via a snapshot step — D1 → JSON → git commit → push. If they diverge, git
   wins (the snapshot is idempotent and overwritable).

2. **One file per interaction.** Not a monolithic `interactions.json`. This
   keeps git diffs clean (one new file per new interaction), avoids merge
   conflicts, and lets Astro's glob loader enumerate them efficiently.

3. **Verified only.** Only interactions that pass Webmention verification or
   ActivityPub signature validation are snapshotted to git. Pending/failed
   interactions stay in D1 for retry but do not enter the repo.

4. **Content is truncated.** The snapshot stores a summary of the interaction
   content (first ~500 chars), not the full remote page. This keeps the repo
   lean, avoids storing other people's full posts, and is sufficient for
   rendering a comment thread.

5. **Author data is a snapshot.** The `author` object is a frozen point-in-time
   copy of the sender's h-card / AP actor at verification time. It is not
   live-updated — if the sender changes their name/photo, the old values persist
   in the snapshot. This is standard IndieWeb practice.

### How the snapshot enters git

The Worker's snapshot step (V-3.4, #362):
1. Queries D1 for interactions verified since the last snapshot timestamp
2. Serializes each to `Source/data/interactions/{id}.json`
3. Commits: `chore: snapshot {n} received interactions`
4. Pushes to the site's repo

The app can trigger this on-demand (from the UI or via an App Intent), or the
Worker can run it on a cron schedule. The commit is a normal git commit — the
user can inspect, revert, or cherry-pick interaction snapshots like any other
content change.

### What about deletion?

If a sender deletes their webmention (sends a 410/404 on re-verification), the
Worker marks the interaction as deleted in D1, and the next snapshot removes the
file from git. This is a normal file deletion + commit.

If the site *owner* wants to hide an interaction (moderation), they delete the
JSON file from their repo. The Worker's D1 record is unaffected (it's operational
data), but the interaction no longer renders on the static site. A future
moderation UI (V-5.3, #370) could add a `moderation` field to the schema instead
of file deletion.

### Astro consumption

`Source/data/interactions/` is loaded by Astro's glob loader at build time.
The page template for each content entry queries interactions where
`target` matches the entry's canonical URL, groups by `interactionType`, and
renders them (replies as a comment thread, likes/reposts as facepile counts).

This is static — the interaction display updates on next build, not in real time.
Real-time display is a future enhancement (WebSocket from the Worker to the
page, or a client-side fetch to the Worker's API).

## Swift schema

The `ReceivedInteraction` type in `Sources/AnglesiteCore/ReceivedInteraction.swift`
is the canonical Swift representation of this schema. It is:

- `Codable` — round-trips through the JSON format described above
- `Sendable` — safe for concurrent use
- `Equatable` — for diffing snapshots
- `Identifiable` — `id` is the stable interaction ID

The `gitPath` computed property returns the relative path within `Source/` where
the interaction should be stored (e.g. `"data/interactions/wm-abc123.json"`).

`InteractionType` provides two display-category helpers:
- `isComment` — true for `.reply` (renders in the threaded comment section)
- `isFacepile` — true for `.like` and `.repost` (renders as avatar facepile)
