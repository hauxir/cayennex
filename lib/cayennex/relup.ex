defmodule Cayennex.Relup do
  @moduledoc """
  Generates a `relup` for an upgrade, given an assembled release directory that
  contains BOTH the new version (`releases/<new>`, `lib/<app>-<new>`) and the
  old version (`releases/<old>`, `lib/<app>-<old>`).

  Writes `.appup` files for changed apps via `Cayennex.Appup`, drives
  `:systools.make_relup`, then HARDENS the result for naive hot upgrades
  (see `harden/1`). Following the approach from Distillery's assembler.
  """

  alias Cayennex.Appup

  @doc """
  Generate `releases/<new_vsn>/relup`. Returns `{:error, :erts_changed}` when
  the ERTS version differs between releases (relup cannot hot-swap ERTS — the
  caller must fall back to a full deploy).
  """
  @spec generate(String.t(), atom, String.t(), String.t()) :: :ok | {:error, term}
  def generate(output_dir, name, old_vsn, new_vsn) do
    v1_rel = Path.join([output_dir, "releases", old_vsn, "#{name}.rel"])
    v2_rel = Path.join([output_dir, "releases", new_vsn, "#{name}.rel"])

    cond do
      not File.exists?(v1_rel) -> {:error, {:missing_rel, v1_rel}}
      not File.exists?(v2_rel) -> {:error, {:missing_rel, v2_rel}}
      erts_vsn(v1_rel) != erts_vsn(v2_rel) -> {:error, :erts_changed}
      true -> do_generate(output_dir, name, old_vsn, new_vsn, v1_rel, v2_rel)
    end
  end

  defp do_generate(output_dir, name, old_vsn, new_vsn, v1_rel, v2_rel) do
    rel_dir = Path.join([output_dir, "releases", new_vsn])
    v1_apps = relfile_apps(v1_rel)
    v2_apps = relfile_apps(v2_rel)
    changed = changed_apps(v1_apps, v2_apps)
    added = added_apps(v1_apps, v2_apps)
    removed = removed_apps(v1_apps, v2_apps)

    with :ok <- generate_appups(changed, output_dir) do
      current =
        Path.join([output_dir, "releases", new_vsn, "#{name}"]) |> String.to_charlist()

      upfrom =
        Path.join([output_dir, "releases", old_vsn, "#{name}"]) |> String.to_charlist()

      result =
        :systools.make_relup(
          current,
          [upfrom],
          [upfrom],
          [
            {:outdir, String.to_charlist(rel_dir)},
            {:path, code_paths(added, changed, removed, new_vsn, old_vsn, output_dir)},
            :silent,
            :no_warn_sasl
          ]
        )

      case result do
        {:ok, relup, _mod, []} ->
          write_term(Path.join(rel_dir, "relup"), harden(relup))

        {:ok, relup, _mod, warnings} ->
          # Surface (don't swallow) systools warnings — they can flag skipped
          # modules / version mismatches it worked around. (missing_sasl is
          # separately suppressed by :no_warn_sasl, and sasl is in the release.)
          Mix.shell().info("make_relup warnings: #{inspect(warnings)}")
          write_term(Path.join(rel_dir, "relup"), harden(relup))

        {:error, mod, errors} ->
          {:error, {:make_relup, mod, errors}}
      end
    end
  end

  # --- app diffing ---------------------------------------------------------

  defp relfile_apps(path) do
    {:ok, [{:release, _rel, _erts, apps}]} = :file.consult(String.to_charlist(path))

    Enum.map(apps, fn
      {a, v} -> {a, v}
      {a, v, _start_type} -> {a, v}
      {a, v, _start_type, _included} -> {a, v}
    end)
  end

  defp erts_vsn(rel_path) do
    {:ok, [{:release, _rel, {:erts, erts}, _apps}]} =
      :file.consult(String.to_charlist(rel_path))

    erts
  end

  defp changed_apps(a, b) do
    as = MapSet.new(a, &elem(&1, 0))
    bs = MapSet.new(b, &elem(&1, 0))
    shared = MapSet.intersection(as, bs) |> MapSet.to_list()

    shared
    |> Enum.map(fn n -> {n, ver(a, n), ver(b, n)} end)
    |> Enum.reject(fn {_n, v1, v2} -> v1 == v2 end)
    |> Enum.map(fn {n, v1, v2} -> {n, "#{v1}", "#{v2}"} end)
  end

  # Apps genuinely new in v2 (absent from v1) — mirrors removed_apps. Only
  # feeds code_paths today, but the name should mean what it says.
  defp added_apps(v1_apps, v2_apps) do
    v1n = MapSet.new(v1_apps, &elem(&1, 0))
    v2n = MapSet.new(v2_apps, &elem(&1, 0))

    MapSet.difference(v2n, v1n)
    |> MapSet.to_list()
    |> Enum.map(fn n -> {n, ver(v2_apps, n)} end)
  end

  defp removed_apps(a, b) do
    as = MapSet.new(a, &elem(&1, 0))
    bs = MapSet.new(b, &elem(&1, 0))

    MapSet.difference(as, bs)
    |> MapSet.to_list()
    |> Enum.map(fn n -> {n, ver(a, n)} end)
  end

  defp ver(apps, name), do: apps |> List.keyfind(name, 0) |> elem(1)

  # --- appup generation ----------------------------------------------------

  defp generate_appups([], _output_dir), do: :ok

  defp generate_appups([{app, v1, v2} | rest], output_dir) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}"])
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}"])
    target = Path.join([v2_path, "ebin", "#{app}.appup"])

    case Appup.make(app, v1, v2, v1_path, v2_path) do
      {:ok, appup} ->
        with :ok <- write_term(target, appup), do: generate_appups(rest, output_dir)

      {:error, _} = err ->
        err
    end
  end

  # --- code paths ----------------------------------------------------------
  # Both versions' changed/added/removed app ebins, plus the per-release
  # consolidated-protocols dirs. NOTE: mix release puts consolidated at
  # releases/<vsn>/consolidated (Distillery used lib/<app>-<vsn>/consolidated).
  defp code_paths(added, changed, removed, new_vsn, old_vsn, output_dir) do
    ebin = fn app, v ->
      Path.join([output_dir, "lib", "#{app}-#{v}", "ebin"]) |> String.to_charlist()
    end

    consolidated = fn v ->
      Path.join([output_dir, "releases", v, "consolidated"]) |> String.to_charlist()
    end

    added_paths = Enum.map(added, fn {a, v} -> ebin.(a, v) end)
    removed_paths = Enum.map(removed, fn {a, v} -> ebin.(a, v) end)

    changed_paths =
      Enum.flat_map(changed, fn {a, v1, v2} -> [ebin.(a, v2), ebin.(a, v1)] end)

    [consolidated.(new_vsn), consolidated.(old_vsn)] ++
      added_paths ++ changed_paths ++ removed_paths
  end

  # --- relup hardening -----------------------------------------------------

  @strip_instructions [:suspend, :resume, :code_change]

  @doc """
  Rewrites a `:systools`-generated relup for *naive* hot upgrades.

  `:systools.make_relup` emits `brutal_purge` by default and inserts
  `suspend`/`resume`/`code_change` for "special" processes. `brutal_purge`
  kills any process still running old code; with large compile-time dependency
  graphs (e.g. Absinthe) a single upgrade can touch 150+ modules, so a brutal
  purge would cascade-kill live processes.

  These naive upgrades never rely on `code_change/3` (new callbacks must
  tolerate old state), so the suspend/code_change/resume dance is dead weight
  that only widens the window where a process can be caught mid-swap.

  So this rewrite: `brutal_purge -> soft_purge` (a module that still has old
  code simply isn't purged; the upgrade proceeds) and drops
  `suspend`/`resume`/`code_change` instructions.
  """
  @spec harden(term) :: term
  def harden(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&harden/1)
    |> List.to_tuple()
  end

  def harden(:brutal_purge), do: :soft_purge

  def harden(instructions) when is_list(instructions) do
    instructions
    |> Enum.reject(fn
      t when is_tuple(t) -> elem(t, 0) in @strip_instructions
      _ -> false
    end)
    |> Enum.map(&harden/1)
  end

  def harden(other), do: other

  defp write_term(path, term) do
    File.write(path, :io_lib.format(~c"~p.~n", [term]))
  end
end
