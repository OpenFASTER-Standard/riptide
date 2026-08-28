defmodule Riptide.Derivation.Parser do
  @moduledoc """
  Parses the Soufflé-shaped Datalog-clause concrete syntax (design spec
  §3, §6) into `Riptide.Derivation.Rule` structs.
  """

  import NimbleParsec

  alias Riptide.Derivation.{Rule, Signature, Var}
  alias Riptide.Derivation.Literal.FactPattern

  @relation_ns "urn:riptide:relation:"

  # `@capability_ns`/`@rule_ns` are intentionally NOT defined yet: unlike
  # unused local variables, Elixir's "module attribute set but never used"
  # warning isn't suppressed by an underscore prefix (confirmed empirically
  # against `mix compile --warnings-as-errors`), so the brief's suggested
  # `_capability_ns`/`_rule_ns` fallback doesn't actually work. Task 3, which
  # adds capability(...)/rule(...) literal support and is the first to need
  # these namespaces, should introduce them at that point instead.

  # Datalog rule text is expected to be a single small clause, far smaller
  # than a Turtle document — see `Riptide.RDF.TurtleCodec.decode/1` for the
  # same untrusted-input heap-cap pattern this mirrors (design spec §8).
  @max_heap_size_words 5_000_000

  ws = ignore(repeat(ascii_char([?\s, ?\t, ?\n, ?\r])))

  lower_identifier =
    ascii_char([?a..?z])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})

  upper_identifier =
    ascii_char([?A..?Z])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})

  bracketed_iri =
    ignore(ascii_char([?<]))
    |> repeat(lookahead_not(ascii_char([?>])) |> utf8_char([]))
    |> ignore(ascii_char([?>]))
    |> reduce({List, :to_string, []})

  quoted_string =
    ignore(ascii_char([?"]))
    |> repeat(lookahead_not(ascii_char([?"])) |> utf8_char([]))
    |> ignore(ascii_char([?"]))
    |> reduce({List, :to_string, []})

  variable_term = upper_identifier |> map({__MODULE__, :build_var, []})
  iri_term = bracketed_iri |> map({__MODULE__, :build_iri, []})
  string_term = quoted_string |> map({__MODULE__, :build_string, []})

  term = choice([variable_term, iri_term, string_term])

  predicate_name =
    choice([
      lower_identifier |> map({__MODULE__, :build_relation_name, []}),
      bracketed_iri |> map({__MODULE__, :build_iri, []})
    ])

  term_list =
    ignore(ascii_char([?(]))
    |> concat(ws)
    |> concat(term)
    |> concat(ws)
    |> repeat(ignore(ascii_char([?,])) |> concat(ws) |> concat(term) |> concat(ws))
    |> ignore(ascii_char([?)]))
    |> wrap()

  fact_atom =
    predicate_name
    |> concat(ws)
    |> concat(term_list)
    |> wrap()
    |> map({__MODULE__, :build_fact_pattern, []})

  # For fact-pattern-only rules (this task), a body literal is always a
  # fact-pattern atom. `choice/2` requires at least two alternatives, so a
  # single-element `choice([fact_atom])` doesn't compile — Task 3 reinstates
  # a real `choice/2` here once capability(...)/rule(...) literals exist.
  literal = fact_atom

  body =
    literal
    |> concat(ws)
    |> repeat(ignore(ascii_char([?,])) |> concat(ws) |> concat(literal) |> concat(ws))
    |> wrap()

  defparsecp(
    :do_parse,
    ws
    |> concat(fact_atom)
    |> concat(ws)
    |> ignore(string(":-"))
    |> concat(ws)
    |> concat(body)
    |> concat(ws)
    |> ignore(ascii_char([?.]))
    |> concat(ws)
    |> eos()
  )

  @doc """
  Parses Datalog-clause text into a `Riptide.Derivation.Rule.t()`. Applies
  a per-process heap cap first (design spec §8) since this parses
  untrusted/LLM-authored text.
  """
  @spec decode(String.t()) :: {:ok, Rule.t()} | {:error, term()}
  def decode(text) when is_binary(text) do
    Process.flag(:max_heap_size, %{size: @max_heap_size_words, kill: true, error_logger: true})

    case do_parse(text) do
      {:ok, [head, body], "", _, _, _} -> {:ok, build_rule(head, body)}
      {:error, reason, rest, _, _, _} -> {:error, {reason, rest}}
    end
  end

  @doc false
  def build_var(name), do: %Var{name: name}

  @doc false
  def build_iri(iri_string), do: RDF.iri(iri_string)

  @doc false
  def build_string(str), do: RDF.literal(str)

  @doc false
  def build_relation_name(name), do: RDF.iri(@relation_ns <> name)

  @doc false
  def build_fact_pattern([predicate, args]), do: %FactPattern{predicate: predicate, args: args}

  defp build_rule(%FactPattern{} = head, body) do
    %Rule{signature: build_signature(head, body), head: head, body: body}
  end

  defp build_signature(%FactPattern{predicate: name, args: params}, body) do
    reads =
      body
      |> Enum.filter(&match?(%FactPattern{}, &1))
      |> Enum.map(& &1.predicate)
      |> Enum.uniq()

    %Signature{name: name, parameters: params, reads: reads, produces: [name]}
  end
end
