defmodule Riptide.Capability.DefinitionTest do
  use ExUnit.Case, async: true

  alias Riptide.Capability.Definition

  test "carries name, kind, component, function, fuel_limit, timeout_ms, memory_limits" do
    definition = %Definition{
      name: RDF.iri("urn:riptide:capability:greetSomeone"),
      kind: :effect,
      component: "test/fixtures/riptide_capability/fixture.wasm",
      function: "greet",
      fuel_limit: 10_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }

    assert definition.name == RDF.iri("urn:riptide:capability:greetSomeone")
    assert definition.kind == :effect
    assert definition.function == "greet"
    assert definition.fuel_limit == 10_000_000
  end
end
