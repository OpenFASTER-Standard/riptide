# Seeds "The Story So Far"'s tenant policy and opening line. NOT a
# standalone `mix run` script — running it as a separate OS process would
# race the already-running `mix phx.server` for the same on-disk Ra data
# files. Load it into that ALREADY-RUNNING process instead, from a
# Riptide checkout, with the server not yet started:
#
#   HOSTNAME=riptide-0 iex -S mix phx.server -e 'Code.eval_file("examples/live-story/setup.exs")'
#
# Wait for the printed confirmation, then open examples/live-story/index.html
# in a browser. Leave this terminal open — it's your running server.
alias Riptide.Authz.{Policy, Store}
alias Riptide.Event
alias Riptide.Stream.{StreamServer, StreamSupervisor}

tenant_id = "story-demo"
stream_id = "https://riptide.example/tenants/#{tenant_id}/resources/the-story"

:ok =
  Store.Placement.add_policy(tenant_id, [], %Policy{
    effect: :allow,
    modes: [:read, :write],
    matcher: :public
  })

:ok = StreamSupervisor.ensure_ready(stream_id)

opening_line_id = "urn:uuid:" <> Uniq.UUID.uuid4()
rdf_type = RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
schema_creative_work = RDF.iri("http://schema.org/CreativeWork")
schema_text = RDF.iri("http://schema.org/text")
schema_author = RDF.iri("http://schema.org/author")

opening_graph =
  RDF.Graph.new()
  |> RDF.Graph.add({RDF.iri(opening_line_id), rdf_type, schema_creative_work})
  |> RDF.Graph.add(
    {RDF.iri(opening_line_id), schema_text,
     "Once, in a kingdom made of tea and thunder, a fox found a door that wasn't there yesterday."}
  )
  |> RDF.Graph.add({RDF.iri(opening_line_id), schema_author, "the Narrator"})

StreamServer.append(stream_id, Event.new(stream_id, :replace, opening_graph))

IO.puts("""

================================================================
"The Story So Far" is ready.
  Tenant:  #{tenant_id} (public read+write policy seeded)
  Story:   #{stream_id}
Open examples/live-story/index.html in a browser to start writing.
================================================================
""")
