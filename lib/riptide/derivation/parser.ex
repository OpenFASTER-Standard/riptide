defmodule Riptide.Derivation.Parser do
  @moduledoc """
  Parses the Soufflé-shaped Datalog-clause concrete syntax (design spec
  §3, §6) into `Riptide.Derivation.Rule` structs.
  """

  import NimbleParsec

  alias Riptide.Derivation.{Rule, Signature, Var}
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.Literal.{CapabilityReference, RuleReference}

  @relation_ns "urn:riptide:relation:"
  @capability_ns "urn:riptide:capability:"
  @rule_ns "urn:riptide:rule:"

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

  capability_or_rule_args =
    ignore(ascii_char([?(]))
    |> concat(ws)
    |> concat(lower_identifier)
    |> concat(ws)
    |> repeat(ignore(ascii_char([?,])) |> concat(ws) |> concat(term) |> concat(ws))
    |> ignore(ascii_char([?)]))
    |> wrap()

  capability_literal =
    ignore(string("capability"))
    |> concat(ws)
    |> concat(capability_or_rule_args)
    |> map({__MODULE__, :build_capability_reference, []})

  rule_literal =
    ignore(string("rule"))
    |> concat(ws)
    |> concat(capability_or_rule_args)
    |> map({__MODULE__, :build_rule_reference, []})

  fact_atom =
    predicate_name
    |> concat(ws)
    |> concat(term_list)
    |> wrap()
    |> map({__MODULE__, :build_fact_pattern, []})

  literal = choice([capability_literal, rule_literal, fact_atom])

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

  @doc false
  def build_capability_reference([name | rest]) do
    {args, [result]} = Enum.split(rest, length(rest) - 1)
    %CapabilityReference{capability: RDF.iri(@capability_ns <> name), args: args, result: result}
  end

  @doc false
  def build_rule_reference([name | rest]) do
    {args, [result]} = Enum.split(rest, length(rest) - 1)
    %RuleReference{rule: RDF.iri(@rule_ns <> name), args: args, result: result}
  end

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
