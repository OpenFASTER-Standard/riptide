# The Story So Far

A tiny, joyful Riptide example: a single shared story that anyone here adds the next line to,
live — every open tab watches it grow with no refresh. Built to show what's actually different
about Riptide: live event delivery, append-only history, resumable cursors, and the fact that it's
genuinely Linked Data underneath, not a chat log with extra steps.

## Running it

From a Riptide checkout:

```bash
mix deps.get
iex -S mix phx.server -e 'Code.eval_file("examples/live-story/setup.exs")'
```

Wait for the confirmation banner, then open `examples/live-story/index.html` directly in a
browser — no server needed for the page itself, no build step, nothing else to fetch: the page is
a single, standalone HTML file with its CSS and JavaScript inlined, so it works exactly the same
whether you open it from this checkout or download and double-click just that one file on its own.
Open it in a second tab (or a second browser) to watch lines you add in one appear live in the
other.

Leave the `iex` session running — it's your live server. Stop it with Ctrl-C (twice) when done.

Talking to a server somewhere other than `localhost:4000` (e.g. a Fly.io deployment — see the root
README's "Running on Fly.io" section)? Open `index.html?base=https://your-server-host` instead of
the bare file — the inline script reads the `base` query param and defaults to
`http://localhost:4000` only when it's absent.

## What to look at

- Type a line and submit it — watch it appear on every open tab immediately.
- Click "Peek at the data" to see the raw Turtle triples behind the most recent line — this is
  the literal wire payload of a `PATCH` event streamed straight from `index.html`'s own inline SSE
  reader, not a stringified JSON blob.
- `examples/live-story/index.html`'s inline `<script>` is deliberately small and un-minified — read
  it to see exactly how a browser client talks to Riptide: one `PATCH` to submit a line, one
  `fetch()`-based SSE reader (not the native `EventSource` API — see the comment in
  `subscribeOnce()` for why) to receive the full history and every future line live.

## Watching it as a graph

Want to see `the-story`'s actual RDF structure grow live instead of prose? See the
[live RDF graph viewer](../graph-viewer/) example — a separate, general-purpose tool (not specific
to this demo) that renders any Riptide resource's triples as a live WebGL graph. Point it at
`story-demo`/`the-story` on whichever server you're running this example against.
