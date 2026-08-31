defmodule Riptide.BlobStore do
  @moduledoc """
  Privileged, content-addressed blob storage — see design spec
  `docs/superpowers/specs/2026-08-30-phase-6j-large-object-blob-storage-design.md`.
  Outside the WASI sandbox by design (§4/§9): performs no authorization of its
  own, every caller is responsible for that. This module covers only
  single-node local storage; cross-node replication is layered on top in
  `put/1`'s own SupervisedProcess-wrapped `GenServer` (Task 3).
  """

  @spec put(binary()) :: {:ok, String.t()} | {:error, term()}
  def put(bytes) when is_binary(bytes) do
    hash = hash_of(bytes)
    path = path_for(hash)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      {:ok, hash}
    end
  end

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(hash) do
    case File.read(path_for(hash)) do
      {:ok, bytes} -> verify(bytes, hash)
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # A locally-stored blob whose bytes don't match their own claimed hash is
  # corruption, not a valid result (spec §5) — never served silently.
  defp verify(bytes, hash) do
    if hash_of(bytes) == hash do
      {:ok, bytes}
    else
      {:error, :not_found}
    end
  end

  defp hash_of(bytes),
    do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  # Two-level directory prefix (matching git's own object-store layout) so a
  # single directory never accumulates an unbounded number of entries.
  defp path_for(hash) do
    <<prefix::binary-size(2), rest::binary>> = hash
    Path.join([data_dir(), prefix, rest])
  end

  defp data_dir do
    Application.get_env(:riptide, :blob_data_dir) || System.get_env("RIPTIDE_BLOB_DATA_DIR") ||
      "priv/blob_data"
  end
end
