defmodule Riptide.Accounts do
  @moduledoc """
  Signup and login for Riptide's own username/password authentication
  (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`).
  Both functions call the low-level stream read/write primitives directly
  (mirroring `Riptide.Derivation.Catalog`'s own private `write_patch/3`/
  `read_graph/1`) rather than going through
  `RiptideWeb.LDP.ResourceController`'s generic, Authz-checked HTTP path —
  there is no verified token yet at the point either of these run, so that
  path isn't reachable in the first place (§4.2, §4.3 of the design spec).
  """

  alias Riptide.Accounts.{Account, RDFCodec}
  alias Riptide.Auth.PasswordTokenConfig
  alias Riptide.Authz.Store.TenantFacts
  alias Riptide.Event
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @spec sign_up(String.t(), String.t(), String.t()) ::
          {:ok, %{token: String.t(), sub: String.t(), tenant_id: String.t()}}
          | {:error, :already_claimed}
          | {:error, :not_ready}
  def sign_up(name, username, password_hash_sha256) do
    tenant_id = Uniq.UUID.uuid4()
    sub = Uniq.UUID.uuid4()

    case Riptide.Placement.claim_name(name, tenant_id) do
      :already_claimed ->
        {:error, :already_claimed}

      :claimed ->
        account = %Account{
          username: username,
          password_hash_sha256: password_hash_sha256,
          sub: sub
        }

        owner_policy = %Riptide.Authz.Policy{
          effect: :allow,
          modes: [:read, :write],
          matcher: {:agent, sub}
        }

        with :ok <- write_account(tenant_id, username, account),
             :ok <- TenantFacts.add_policy(tenant_id, [], owner_policy),
             {:ok, token} <- PasswordTokenConfig.sign(sub) do
          {:ok, %{token: token, sub: sub, tenant_id: tenant_id}}
        end
    end
  end

  @spec log_in(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_credentials} | {:error, :not_ready}
  def log_in(name, username, password_hash_sha256) do
    case Riptide.Placement.lookup_name(name) do
      nil ->
        {:error, :invalid_credentials}

      tenant_id ->
        with {:ok, account} <- read_account(tenant_id, username) do
          verify_password(account, password_hash_sha256)
        end
    end
  end

  defp verify_password(%Account{password_hash_sha256: hash} = account, hash),
    do: PasswordTokenConfig.sign(account.sub)

  defp verify_password(_account, _password_hash_sha256), do: {:error, :invalid_credentials}

  defp write_account(tenant_id, username, %Account{} = account) do
    stream_id = ResourceController.stream_id_for({:tenant, tenant_id}, ["accounts", username])
    {_node, graph} = RDFCodec.to_rdf(account)
    write_patch(stream_id, RDF.Graph.triples(graph), [])
  end

  defp read_account(tenant_id, username) do
    stream_id = ResourceController.stream_id_for({:tenant, tenant_id}, ["accounts", username])

    with {:ok, graph} <- read_graph(stream_id),
         node when not is_nil(node) <- find_account_node(graph) do
      {:ok, RDFCodec.from_rdf(node, graph)}
    else
      nil -> {:error, :invalid_credentials}
      {:error, _reason} -> {:error, :invalid_credentials}
    end
  end

  # Each account is a single-entry stream (design spec §4.1) — exactly one
  # subject, or none at all if the stream has never been written. Mirrors
  # `Riptide.BlobStore.LocationIndex.list_all/0`'s own `RDF.Graph.subjects/1`
  # usage for finding relevant subjects in a folded graph.
  defp find_account_node(graph) do
    graph |> RDF.Graph.subjects() |> Enum.at(0)
  end

  defp write_patch(stream_id, additions, removals) do
    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        StreamServer.append(
          stream_id,
          Event.new(stream_id, :patch, %Patch{additions: additions, removals: removals})
        )

        :ok

      :error ->
        {:error, :not_ready}
    end
  end

  defp read_graph(stream_id) do
    case Riptide.Placement.lookup(stream_id) do
      nil -> {:ok, RDF.Graph.new()}
      _nodes -> read_existing_graph(stream_id)
    end
  end

  defp read_existing_graph(stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        case StreamServer.get_since(stream_id, 0) do
          {:ok, events} -> {:ok, fold_events(events)}
          {:gap, _oldest} -> {:ok, RDF.Graph.new()}
        end

      :error ->
        {:error, :not_ready}
    end
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :replace, payload: payload}, _acc -> payload
      %Event{operation: :delete}, _acc -> RDF.Graph.new()
      %Event{operation: :patch, payload: %Patch{} = patch}, acc -> Patch.apply(acc, patch)
    end)
  end
end
