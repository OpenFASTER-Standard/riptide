# The Story So Far

A tiny, joyful Riptide example: a single shared story that anyone here adds the next line to,
live — every open tab watches it grow with no refresh. Built to show what's actually different
about Riptide: live event delivery, append-only history, resumable cursors, and the fact that it's
genuinely Linked Data underneath, not a chat log with extra steps.

## Running it

From a Riptide checkout (see the top-level README's own "Running locally for development" section
for why `HOSTNAME` matters here):

```bash
mix deps.get
HOSTNAME=riptide-0 iex -S mix phx.server -e 'Code.eval_file("examples/live-story/setup.exs")'
```

Wait for the confirmation banner, then open `examples/live-story/index.html` directly in a
browser — no server needed for the page itself, no build step. Open it in a second tab (or a
second browser) to watch lines you add in one appear live in the other.

Leave the `iex` session running — it's your live server. Stop it with Ctrl-C (twice) when done.

## What to look at

- Type a line and submit it — watch it appear on every open tab immediately.
- Click "Peek at the data" to see the raw Turtle triples behind the most recent line — this is
  the literal wire payload of a `PATCH` event streamed straight from `examples/live-story/app.js`'s
  own SSE reader, not a stringified JSON blob.
- `examples/live-story/app.js` is deliberately small and un-minified — read it to see exactly how
  a browser client talks to Riptide: one `PATCH` to submit a line, one `fetch()`-based SSE reader
  (not the native `EventSource` API — see the comment in `subscribeOnce()` for why) to receive the
  full history and every future line live.
