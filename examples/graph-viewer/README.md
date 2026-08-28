# Live RDF graph viewer

A general-purpose companion tool, not tied to any specific app or dataset: point it at any
Riptide resource and watch its actual RDF triples grow live as a WebGL node-link graph, using
[Sigma.js](https://www.sigmajs.org/) — every subject and object becomes a node (gold for literal
values, blue for IRIs — entities and types), every predicate becomes an edge, and new nodes ease
into place via a small live force-directed layout as the resource is written to.

## Running it

Open `examples/graph-viewer/index.html` directly in a browser — no server needed for the page
itself, no build step, nothing else to fetch beyond Sigma.js/graphology (loaded from a CDN — see
"Dependencies" below). With no `base`/`tenant`/`resource` query params, it shows a small connect
form instead of assuming any particular resource:

- **Server base URL** — a running Riptide instance, e.g. `http://localhost:4000` for local dev, or
  a deployed instance's URL (see the root README's "Running on Fly.io" section for one way to get
  one).
- **Tenant** and **Resource path** — which resource to watch, e.g. `story-demo` /
  `the-story` to point it at the [live-story](../live-story/) example.

Submitting the form reloads the page with those three as query params
(`?base=...&tenant=...&resource=...`), which is also how to bookmark or share a specific view
directly — open a URL like that and it connects immediately, skipping the form. To watch a
different resource later, click "Watch a different resource" in the header (or just edit the URL).

## Drag to reposition

Click and drag any node — it's pinned to the cursor while dragging (highlighted with a ring so
it's clear which one you've grabbed) and rejoins the live layout normally the moment you release
it, rather than staying stuck wherever you dropped it.

## Dependencies

Loads Sigma.js and its `graphology` graph library from a CDN, via [esm.sh](https://esm.sh/) rather
than a raw `jsdelivr` dist file — see the comment above the imports in `index.html` for why:
graphology's own browser build imports Node's `events` module, which only `esm.sh` resolves for a
plain `<script type="module">` with no bundler. This means, unlike a fully offline single-file
example, this page needs real internet access to that CDN — not just to whatever Riptide server
you point it at.

## Known limitation

This only ever applies triples from a `:patch`'s *additions* — it doesn't handle `:delete`,
`:replace`, or patch *removals*. A resource whose writes only ever append (like
[live-story](../live-story/)'s) renders correctly forever; a resource that actually mutates or
shrinks will drift from its real current state the moment that happens. Handling that correctly
is real added complexity (tracking which nodes/edges came from which triple, to remove them again)
that this first general-purpose pass doesn't yet include.
