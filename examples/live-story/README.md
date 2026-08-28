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

`examples/live-story/graph.html` is a second, independent page — open it in a third tab alongside
`index.html` — that renders `the-story`'s actual RDF structure live with
[Sigma.js](https://www.sigmajs.org/) (WebGL) instead of prose: every subject and object becomes a
node (gold for literal values like the submitted text/author, blue for IRIs — entities and types),
every predicate becomes an edge, and new nodes ease into place via a small live force-directed
layout as lines get submitted. It talks to the exact same SSE stream `index.html` does, so nothing
on the server needs to change to watch it.

Unlike `index.html` (hardcoded to `story-demo`/`the-story`), `graph.html` is a general RDF graph
viewer — point it at any tenant/resource with `?tenant=` and `?resource=` query params (both
default to `story-demo`/`the-story` so it shows this demo out of the box), combined with the same
`?base=` override as `index.html` for a non-local server:

```
graph.html?base=https://your-server-host&tenant=story-demo&resource=the-story
```

It loads Sigma.js and its `graphology` graph library from a CDN (via `esm.sh`, not a bare
`jsdelivr` dist file — see the comment above the imports in `graph.html` for why: graphology's own
browser build imports Node's `events` module, which only `esm.sh` resolves for a plain
`<script type="module">` with no bundler), so unlike `index.html` it needs real internet access to
that CDN, not just to your Riptide server.

Scoped deliberately to what `the-story` actually does: it only ever handles `:patch` *additions*
(the only operation this demo ever sends), not `:delete`/`:replace` or patch removals — a resource
that actually mutates or shrinks would need that handled, which is out of scope here.
