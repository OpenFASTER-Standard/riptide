defmodule Riptide.RDF.PatchTest do
  use ExUnit.Case, async: true

  alias Riptide.RDF.Patch

  @alice RDF.iri("https://pod.example/alice")
  @name RDF.iri("https://pod.example/name")

  test "apply/2 adds triples from the additions list" do
    graph = RDF.Graph.new()
    patch = %Patch{additions: [{@alice, @name, RDF.literal("Alice")}], removals: []}

    result = Patch.apply(graph, patch)

    assert RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
  end

  test "apply/2 removes triples from the removals list" do
    graph = RDF.Graph.new() |> RDF.Graph.add({@alice, @name, RDF.literal("Alice")})
    patch = %Patch{additions: [], removals: [{@alice, @name, RDF.literal("Alice")}]}

    result = Patch.apply(graph, patch)

    refute RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
  end

  test "apply/2 applies removals before additions, so a replace-in-place works" do
    graph = RDF.Graph.new() |> RDF.Graph.add({@alice, @name, RDF.literal("Alice")})

    patch = %Patch{
      additions: [{@alice, @name, RDF.literal("Alicia")}],
      removals: [{@alice, @name, RDF.literal("Alice")}]
    }

    result = Patch.apply(graph, patch)

    refute RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
    assert RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alicia")})
  end

  test "apply/2 has additions win when the same triple is both added and removed" do
    graph = RDF.Graph.new()

    patch = %Patch{
      additions: [{@alice, @name, RDF.literal("Alice")}],
      removals: [{@alice, @name, RDF.literal("Alice")}]
    }

    result = Patch.apply(graph, patch)

    assert RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
  end

  describe "encode/1 and decode/1" do
    test "round-trips a patch with both additions and removals" do
      patch = %Patch{
        additions: [{@alice, @name, RDF.literal("Alice")}],
        removals: [{@alice, @name, RDF.literal("Bob")}]
      }

      assert Patch.decode(Patch.encode(patch)) == patch
    end

    test "round-trips a patch with empty additions and removals" do
      patch = %Patch{additions: [], removals: []}

      assert Patch.decode(Patch.encode(patch)) == patch
    end

    test "encode/1 produces a version-tagged map" do
      patch = %Patch{additions: [], removals: []}

      assert Patch.encode(patch) == %{v: 1, additions: [], removals: []}
    end

    test "decode/1 raises a clear error on an unrecognized version" do
      assert_raise RuntimeError, ~r/Unknown Patch wire version: 99/, fn ->
        Patch.decode(%{v: 99, additions: [], removals: []})
      end
    end
  end

  describe "encode/1 and decode/1 — RDF-star (phase 6a)" do
    test "a Patch containing a quoted-triple addition round-trips through encode/1 and decode/1, still at wire version 1" do
      alice = RDF.iri("urn:test:alice")
      works_at = RDF.iri("urn:riptide:relation:worksAt")
      acme = RDF.iri("urn:test:acme")
      valid_from = RDF.iri("urn:riptide:relation:validFrom")

      base_triple = {alice, works_at, acme}
      annotation_triple = {base_triple, valid_from, RDF.literal(~U[2026-01-01 00:00:00Z])}

      patch = %Patch{additions: [base_triple, annotation_triple], removals: []}

      assert Patch.encode(patch) == %{
               v: 1,
               additions: [base_triple, annotation_triple],
               removals: []
             }

      assert Patch.decode(Patch.encode(patch)) == patch
    end

    test "an old-shape v1 wire map with no RDF-star anywhere still decodes via the same clause" do
      old_wire = %{v: 1, additions: [{@alice, @name, RDF.literal("Alice")}], removals: []}

      assert Patch.decode(old_wire) == %Patch{
               additions: [{@alice, @name, RDF.literal("Alice")}],
               removals: []
             }
    end
  end
end
