defmodule Riptide.RDF.TurtleCodec do
  @moduledoc """
  Thin wrapper around RDF.Turtle so the rest of Riptide depends on this
  module's stable {:ok, _} | {:error, _} contract rather than the rdf
  library's own (bang vs non-bang) function-naming conventions directly.
  """

  # Turtle's grammar allows unbounded nesting of collections `( ( ( ... ) ) )`
  # and blank-node property lists `[ :p [ :p [ ... ] ] ]`, and the underlying
  # `rdf` library's decoder recurses once per nesting level with no depth
  # limit of its own. Confirmed empirically: a ~3MB body containing 1.5M
  # levels of `(` nesting (well within Plug's default ~8MB body-size cap)
  # drove ~863MB of heap growth and ~19s of CPU in the decoding process
  # before this guard existed — a straightforward, request-sized DoS against
  # any authenticated caller (self-service tenant bootstrap grants any
  # authenticated principal write access to a fresh tenant).
  #
  # `decode/1`'s only callers today (`RiptideWeb.LDP.ResourceController`) run
  # in a short-lived, per-request Phoenix/Cowboy process, so bounding *that
  # process's* heap here is safe — it isn't a long-lived process any other
  # unrelated work shares. 50_000_000 words (~400MB on a 64-bit VM) is
  # generous relative to any legitimate Turtle body under the same ~8MB
  # request-size cap, while still well short of exhausting a typical pod's
  # memory from a single request.
  @max_heap_size_words 50_000_000

  @spec decode(String.t()) :: {:ok, RDF.Graph.t()} | {:error, term()}
  def decode(turtle_string) when is_binary(turtle_string) do
    Process.flag(:max_heap_size, %{size: @max_heap_size_words, kill: true, error_logger: true})

    case RDF.Turtle.read_string(turtle_string) do
      {:ok, graph} -> {:ok, graph}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(RDF.Graph.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%RDF.Graph{} = graph) do
    # An empty graph should round-trip as an empty string. Without this,
    # RDF.Turtle.write_string/1 still emits its default prefix directives
    # (rdf:/rdfs:/xsd:) for a graph with zero triples, which would make a
    # genuinely-empty resource body (e.g. after a PUT with an empty body)
    # indistinguishable from actual content on the wire.
    #
    # This is an INTENTIONAL, in-scope wire-behavior change for the
    # empty-graph case only (it fixes the empty-PUT bug). Non-empty graphs are
    # unchanged and remain byte-compatible with the previous output. Do not
    # "restore" the prefix-only boilerplate for empty graphs — it is
    # load-bearing, not an oversight.
    if Enum.empty?(RDF.Graph.triples(graph)) do
      {:ok, ""}
    else
      case RDF.Turtle.write_string(graph) do
        {:ok, turtle} -> {:ok, turtle}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
