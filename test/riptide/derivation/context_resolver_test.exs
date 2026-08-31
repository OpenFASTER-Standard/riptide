defmodule Riptide.Derivation.ContextResolverTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore

  alias Riptide.Derivation.{
    CapabilityCatalogEntry,
    Catalog,
    ContextResolver,
    DedupGate,
    Rule,
    Signature
  }

  defp unique_tenant, do: "ctxres-acme-#{System.unique_integer([:positive])}"

  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp cap(name), do: RDF.iri("urn:riptide:capability:" <> name)

  setup do
    dir = Path.join(System.tmp_dir!(), "ctxres_blob_#{System.unique_integer([:positive])}")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  defp admit_capability!(name) do
    {:ok, hash} = BlobStore.put(:crypto.strong_rand_bytes(32))

    entry = %CapabilityCatalogEntry{
      name: cap(name),
      kind: :effect,
      component_hash: hash,
      function: "run",
      fuel_limit: 10_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }

    review_scope = {:tenant, "ctxres-review-#{System.unique_integer([:positive])}"}
    {:ok, node} = DedupGate.propose_capability(review_scope, entry)
    :ok = DedupGate.approve_capability_review(review_scope, node)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(review_scope))
    end)

    entry
  end

  defp admit_rule!(scope, name, body) do
    rule = %Rule{
      signature: %Signature{name: rel(name), parameters: [], reads: [], produces: [rel(name)]},
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: rel(name),
        args: [rel("subject"), rel("object")]
      },
      body: body
    }

    :ok = Catalog.admit_entry(scope, rule, nil)
    rule
  end

  test "resolves a Rule with no references" do
    scope = {:tenant, unique_tenant()}
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)
    {:tenant, tenant_id} = scope

    rule = admit_rule!(scope, "leaf-#{System.unique_integer([:positive])}", [])
    rule_iri = rule.signature.name

    assert {:ok, context} = ContextResolver.resolve(tenant_id, nil, rule_iri)
    assert map_size(context.capabilities) == 0
    assert map_size(context.rules) == 1
    assert Map.has_key?(context.rules, rule_iri)
    assert context.tenant_id == tenant_id
  end

  test "transitively resolves a Rule referencing a Capability and a nested Rule" do
    scope = {:tenant, unique_tenant()}
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)
    {:tenant, tenant_id} = scope

    cap_entry = admit_capability!("ctxres-cap-#{System.unique_integer([:positive])}")

    inner_iri = rel("ctxres-inner-#{System.unique_integer([:positive])}")

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{name: inner_iri, parameters: [], reads: [], produces: [inner_iri]},
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: inner_iri,
            args: [rel("s"), rel("o")]
          },
          body: []
        },
        nil
      )

    outer_iri = rel("ctxres-outer-#{System.unique_integer([:positive])}")

    outer_rule = %Rule{
      signature: %Signature{name: outer_iri, parameters: [], reads: [], produces: [outer_iri]},
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: outer_iri,
        args: [rel("s"), rel("o")]
      },
      body: [
        %Riptide.Derivation.Literal.CapabilityReference{
          capability: cap_entry.name,
          args: [RDF.literal("x")],
          result: rel("capResult")
        },
        %Riptide.Derivation.Literal.RuleReference{
          rule: inner_iri,
          args: [rel("s")],
          result: rel("innerResult")
        }
      ]
    }

    :ok = Catalog.admit_entry(scope, outer_rule, nil)

    assert {:ok, context} = ContextResolver.resolve(tenant_id, nil, outer_iri)
    assert Map.has_key?(context.rules, outer_iri)
    assert Map.has_key?(context.rules, inner_iri)
    assert Map.has_key?(context.capabilities, cap_entry.name)
    assert context.capabilities[cap_entry.name].component != nil
  end

  test "a diamond dependency (two Rules sharing one sub-Rule) resolves without error" do
    scope = {:tenant, unique_tenant()}
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)
    {:tenant, tenant_id} = scope

    shared_iri = rel("ctxres-shared-#{System.unique_integer([:positive])}")

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{
            name: shared_iri,
            parameters: [],
            reads: [],
            produces: [shared_iri]
          },
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: shared_iri,
            args: [rel("s"), rel("o")]
          },
          body: []
        },
        nil
      )

    mid_a_iri = rel("ctxres-mid-a-#{System.unique_integer([:positive])}")
    mid_b_iri = rel("ctxres-mid-b-#{System.unique_integer([:positive])}")

    for mid_iri <- [mid_a_iri, mid_b_iri] do
      :ok =
        Catalog.admit_entry(
          scope,
          %Rule{
            signature: %Signature{name: mid_iri, parameters: [], reads: [], produces: [mid_iri]},
            head: %Riptide.Derivation.Literal.FactPattern{
              predicate: mid_iri,
              args: [rel("s"), rel("o")]
            },
            body: [
              %Riptide.Derivation.Literal.RuleReference{
                rule: shared_iri,
                args: [rel("s")],
                result: rel("r")
              }
            ]
          },
          nil
        )
    end

    top_iri = rel("ctxres-top-#{System.unique_integer([:positive])}")

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{name: top_iri, parameters: [], reads: [], produces: [top_iri]},
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: top_iri,
            args: [rel("s"), rel("o")]
          },
          body: [
            %Riptide.Derivation.Literal.RuleReference{
              rule: mid_a_iri,
              args: [rel("s")],
              result: rel("ra")
            },
            %Riptide.Derivation.Literal.RuleReference{
              rule: mid_b_iri,
              args: [rel("s")],
              result: rel("rb")
            }
          ]
        },
        nil
      )

    assert {:ok, context} = ContextResolver.resolve(tenant_id, nil, top_iri)
    assert map_size(context.rules) == 4
  end

  test "a genuine cycle returns {:error, {:cycle_detected, iri}}" do
    scope = {:tenant, unique_tenant()}
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)
    {:tenant, tenant_id} = scope

    a_iri = rel("ctxres-cycle-a-#{System.unique_integer([:positive])}")
    b_iri = rel("ctxres-cycle-b-#{System.unique_integer([:positive])}")

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{name: a_iri, parameters: [], reads: [], produces: [a_iri]},
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: a_iri,
            args: [rel("s"), rel("o")]
          },
          body: [
            %Riptide.Derivation.Literal.RuleReference{
              rule: b_iri,
              args: [rel("s")],
              result: rel("r")
            }
          ]
        },
        nil
      )

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{name: b_iri, parameters: [], reads: [], produces: [b_iri]},
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: b_iri,
            args: [rel("s"), rel("o")]
          },
          body: [
            %Riptide.Derivation.Literal.RuleReference{
              rule: a_iri,
              args: [rel("s")],
              result: rel("r")
            }
          ]
        },
        nil
      )

    assert {:error, {:cycle_detected, ^a_iri}} = ContextResolver.resolve(tenant_id, nil, a_iri)
  end

  test "a missing Rule IRI returns {:error, {:not_found, iri}}" do
    missing = rel("ctxres-missing-#{System.unique_integer([:positive])}")
    assert {:error, {:not_found, ^missing}} = ContextResolver.resolve("acme", nil, missing)
  end

  test "a missing/unapproved Capability referenced in a Rule body returns {:error, {:not_found, iri}}" do
    scope = {:tenant, unique_tenant()}
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)
    {:tenant, tenant_id} = scope

    missing_cap = cap("ctxres-missing-cap-#{System.unique_integer([:positive])}")
    rule_iri = rel("ctxres-refs-missing-#{System.unique_integer([:positive])}")

    :ok =
      Catalog.admit_entry(
        scope,
        %Rule{
          signature: %Signature{name: rule_iri, parameters: [], reads: [], produces: [rule_iri]},
          head: %Riptide.Derivation.Literal.FactPattern{
            predicate: rule_iri,
            args: [rel("s"), rel("o")]
          },
          body: [
            %Riptide.Derivation.Literal.CapabilityReference{
              capability: missing_cap,
              args: [],
              result: rel("r")
            }
          ]
        },
        nil
      )

    assert {:error, {:not_found, ^missing_cap}} =
             ContextResolver.resolve(tenant_id, nil, rule_iri)
  end
end
