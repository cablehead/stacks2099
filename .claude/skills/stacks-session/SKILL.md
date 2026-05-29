---
name: stacks-session
description: >-
  Read and edit clips on a running stacks2099 session (the clip manager served
  over HTTP on a port you choose at startup). Use when asked to put a doc/note/image on a
  stack, iterate on a markdown clip that's open in the app, update the clip
  shown in the current stack, or otherwise change what's on the stream without
  creating a file on disk. Covers the HTTP API (curl) and the direct xs store.
---

# Editing clips on a running stacks2099 session

A clip's content is not a file. It lives in the event log as content-addressed
bytes; the clip frame holds a hash. You "edit" a clip by appending an update.
The clip keeps the same id, and the pane in the browser refreshes on its own.

So the loop is: find the clip, read its bytes, write new bytes back. The clip
stays in place in the stack the whole time.

First you need the server's port. It is not fixed: you pick the port when you
start the server. If the user has not told you the port, ask them for it before
doing anything else. Do not guess or scan. Substitute it for `PORT` below.

## 1. Find the clip

`/api/state` reports the focused (currently shown) clip and stack, plus every
stack with its id, name, and clip count.

```bash
curl -s http://127.0.0.1:PORT/api/state | jq .
# .focusedClip  -> the clip currently shown in the current stack
# .focusedStack -> its stack
```

To edit "the clip on my current stack," target `.focusedClip`.

## 2. Read a clip's current content

```bash
curl -s 'http://127.0.0.1:PORT/clip/blob?clip=CLIP_ID'
```

A 404 / "not found" means the clip has no stored body yet (a fresh empty note)
or it's a terminal clip (terminals stream over `/pty/view`, they have no blob).

## 3. Create a clip (only if one doesn't exist yet)

The body is the content; the mime type comes from the Content-Type header (or
`?mime_type=`). It lands in the current stack unless you pass `?stack=<id|name>`.
The response is the new clip id.

```bash
cat notes.md | curl --data-binary @- \
  -H 'content-type: text/markdown' http://127.0.0.1:PORT/clip/add
# -> prints the new clip id
```

## 4. Update a clip in place (the iterate loop)

Re-post new bytes to an existing clip. Same clip id, same spot in the stack,
pane refreshes live. The mime type is unchanged.

```bash
curl --data-binary @- 'http://127.0.0.1:PORT/clip/update?clip=CLIP_ID' <<'EOF'
# revised markdown
...
EOF
```

To iterate on a markdown doc: read with `/clip/blob`, make your edit, write
back with `/clip/update`, repeat. No files are created.

## Things that will trip you up

- The clip id never changes across updates. Don't create a new clip each time;
  update the existing one.
- If the clip is open in edit mode in the browser (its textarea is showing), the
  server will not repaint it from under you. Your `/clip/update` still lands in
  the log, but it won't show until the clip leaves edit mode. If an update seems
  to "not take," this is usually why. Markdown clips in rendered view repaint
  immediately.
- `/clip/update` keeps the existing mime type. To change the type, close the
  clip and add a new one.

## Alternative: write to the store directly (no HTTP)

The store serves an xs API on its socket, so you can append the same frames the
HTTP routes append. This instance's store is the repo's `./store`; point xs at
it with `XS_ADDR` or the path argument. The user's nu helpers in `~/xs/xs.nu`
(`.append`, `.cat`, `.cas`, `.last`) wrap these.

```bash
# update a clip's body straight on the log (id = the existing clip id)
cat revised.md | xs append ./store clip.update --ttl forever --meta '{"id":"CLIP_ID"}'

# add a new markdown clip (stack_id from /api/state .focusedStack)
cat notes.md | xs append ./store clip.add --ttl forever \
  --meta '{"stack_id":"STACK_ID","kind":"content","mime_type":"text/markdown"}'
```

In a store-connected nushell the builtin form is the same thing:

```nu
open revised.md | .append "clip.update" --meta {id: "CLIP_ID"} --ttl forever
```

Frames: `clip.add {stack_id, kind, mime_type}` (body -> new clip), `clip.update
{id}` (body -> replace that clip's bytes), `clip.patch {id, label?, view?}`
(field change, no body). Use HTTP unless you specifically need to bypass it; the
routes are just sugar over these appends.
