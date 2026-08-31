defmodule Riptide.MultiNodeTestHelpers do
  @moduledoc """
  Shared helper for `:peer`-based multi-node test files — `unique_pairs/1`
  was duplicated byte-for-byte across 10 of them (verified via md5sum
  before extracting). Only ever called from the test process itself (to
  compute which node pairs to `:net_kernel.connect_node/1` between), never
  pushed to or executed on a spawned `:peer` node, so no peer-side
  compilation concerns apply here.
  """

  @spec unique_pairs([node()]) :: [{node(), node()}]
  def unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end

  # `own_module_bytecode/1` was another byte-for-byte duplicate — this time
  # of `[{module, bytecode}] = Code.compile_file(__ENV__.file)` — found
  # across 14 `:peer`-based test files that each push their own already-
  # running module to spawned peers via `:code.load_binary/3` (ExUnit
  # compiles `test/` files purely in-memory, so no `.beam` for them ever
  # lands on disk for a peer's own `-pa <code path>` to find — see any of
  # those files' own `push_module_to_peers/1`-style comment for the full
  # rationale on why the module needs pushing at all).
  #
  # `Code.compile_file(__ENV__.file)` re-*compiles* the caller's `.exs`
  # source from disk every single call — wasteful, and for any file whose
  # peer-bootstrap helper runs more than once (i.e. more than one test in
  # that module), it redefines a module ExUnit's own test loader already
  # has in memory, a real, previously-unnoticed compiler warning
  # ("redefining module ... (current version defined in memory)") showing
  # up in CI output once per redundant call — confirmed live via
  # `placement_cluster_test.exs` (2 tests, so the warning fired twice per
  # run) while root-causing an unrelated CI flake.
  #
  # Tried reusing the module's *already*-compiled bytecode via
  # `:code.get_object_code/1` first — doesn't work: that function resolves
  # a module's `.beam` file via the code path, and `.exs` test files are
  # compiled purely in-memory by `Kernel.ParallelCompiler` with no `.beam`
  # ever written to disk, so it returns `:error` for every one of these
  # modules (confirmed live: all 14 files' tests failed this way on first
  # attempt). Recompiling really is the only way to get the bytecode at
  # all — so instead, memoize it in `:persistent_term` the first time any
  # caller asks for a given module: safe because a module's bytecode is
  # fixed for the lifetime of one `mix test` BEAM (recompiled once by
  # ExUnit's own loader, never again after that), so every caller after
  # the first reuses the same cached binary — one real `Code.compile_file`
  # per module per `mix test` run, no matter how many tests or bootstrap
  # calls need it.
  #
  # That one remaining compile is *still* a guaranteed "redefining module"
  # warning, though — ExUnit's own test loader already defined the module
  # once before any test body (and therefore this function) ever runs, so
  # even a single recompile always redefines it. This isn't an accidental
  # conflict (two different source files fighting over one module name,
  # which is what that warning exists to catch) — it's this exact,
  # understood, intentional recompile-for-bytecode pattern, confirmed by
  # everything above. `Code.compiler_options/1`'s `ignore_module_conflict`
  # is the documented way to tell the compiler exactly that; scoped to just
  # this one `Code.compile_file/1` call (saved and restored immediately
  # after) so it doesn't mask a real conflict warning anywhere else in the
  # same `mix test` run.
  @spec own_module_bytecode(module()) :: binary()
  def own_module_bytecode(module) do
    key = {__MODULE__, :bytecode, module}

    case :persistent_term.get(key, :not_cached) do
      :not_cached -> compile_and_cache(module, key)
      bytecode -> bytecode
    end
  end

  defp compile_and_cache(module, key) do
    source = module.module_info(:compile)[:source] |> List.to_string()
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      [{^module, bytecode}] = Code.compile_file(source)
      :persistent_term.put(key, bytecode)
      bytecode
    after
      Code.compiler_options(previous)
    end
  end
end
