defmodule Riptide.Accounts.Account do
  @moduledoc """
  A single Tenant-scoped login credential — one independently-addressable
  stream per account (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.1), not a member of any shared/global structure. `password_hash_sha256`
  is the client-computed SHA-256 hex digest, stored as-is (§3, §6 of the same
  spec) — this module never sees a raw password. `sub` is a freshly-minted
  UUID, decoupled from both `username` and whichever Tenant this account
  lives under.
  """

  @enforce_keys [:username, :password_hash_sha256, :sub]
  defstruct [:username, :password_hash_sha256, :sub]

  @type t :: %__MODULE__{
          username: String.t(),
          password_hash_sha256: String.t(),
          sub: String.t()
        }
end
