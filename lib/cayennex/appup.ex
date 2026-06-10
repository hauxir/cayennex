defmodule Cayennex.Appup do
  @moduledoc """
  Generates an `.appup` between two versions of an application by diffing their
  compiled BEAMs — the per-application upgrade recipe that
  `:systools.make_relup` turns into a relup.

  Auto-generation only: this assumes no hand-written appups, so the
  `locate`/custom-appup and transform machinery is dropped. The
  instruction-selection and topological-sort logic follows the approach from
  Distillery's appup generator.
  """

  @type instruction :: tuple | atom
  @type appup :: {charlist, [{charlist, [instruction]}], [{charlist, [instruction]}]}

  @doc """
  Build an appup for `application` upgrading `v1` -> `v2`, given the paths to
  the v1 and v2 application directories (each containing `ebin/`).
  """
  @spec make(atom, String.t(), String.t(), String.t(), String.t()) ::
          {:ok, appup} | {:error, term}
  def make(application, v1, v2, v1_path, v2_path) do
    v1_dotapp = dotapp(v1_path, application)
    v2_dotapp = dotapp(v2_path, application)

    case :file.consult(v1_dotapp) do
      {:ok, [{:application, ^application, v1_props}]} ->
        case vsn(v1_props) === v1 do
          true ->
            case :file.consult(v2_dotapp) do
              {:ok, [{:application, ^application, v2_props}]} ->
                case vsn(v2_props) === v2 do
                  true -> {:ok, make_appup(v1, v1_path, v2, v2_path)}
                  false -> {:error, {:mismatched_version, :next, v2, vsn(v2_props)}}
                end

              {:error, reason} ->
                {:error, {:invalid_dotapp, v2_dotapp, reason}}
            end

          false ->
            {:error, {:mismatched_version, :previous, v1, vsn(v1_props)}}
        end

      {:error, reason} ->
        {:error, {:invalid_dotapp, v1_dotapp, reason}}
    end
  end

  defp dotapp(path, application) do
    path
    |> Path.join("ebin")
    |> Path.join("#{application}.app")
    |> String.to_charlist()
  end

  defp make_appup(v1, v1_path, v2, v2_path) do
    v1c = String.to_charlist(v1)
    v2c = String.to_charlist(v2)
    v1_ebin = String.to_charlist(Path.join(v1_path, "ebin"))
    v2_ebin = String.to_charlist(Path.join(v2_path, "ebin"))

    # cmp_dirs returns {Only1, Only2, Different} OR a 3-tuple error
    # {:error, :beam_lib, _}; the is_list guard disambiguates (and lets
    # dialyzer prove `changed`/`added`/`deleted` are lists for the path below).
    {deleted, added, changed} =
      case :beam_lib.cmp_dirs(v1_ebin, v2_ebin) do
        {d, a, c} when is_list(d) and is_list(a) and is_list(c) ->
          {d, a, c}

        other ->
          raise "beam_lib.cmp_dirs failed for #{v1_ebin}/#{v2_ebin}: #{inspect(other)}"
      end

    # Elixir always rewrites the Dbgi (debug info) chunk, so every beam shows
    # as "changed". Ignore that chunk so only genuinely-changed modules count.
    actually_changed =
      Enum.filter(changed, fn {v1_beam, v2_beam} ->
        case :beam_lib.cmp(v1_beam, v2_beam) do
          {:error, :beam_lib, {:chunks_different, ~c"Dbgi"}} -> false
          _ -> true
        end
      end)

    up =
      generate_instructions(:added, added)
      |> Enum.concat(generate_instructions(:changed, actually_changed))
      |> Enum.concat(generate_instructions(:deleted, deleted))

    # For downgrade, old (v1) code is loaded, so the changed-module nature and
    # dependency order must come from the v1 beam. generate_instruction/2 reads
    # nature from the 1st file and imports from the 2nd, so pass {v1, v1}.
    down_changed =
      Enum.map(actually_changed, fn {v1_file, _v2_file} -> {v1_file, v1_file} end)

    down =
      generate_instructions(:deleted, added)
      |> Enum.concat(generate_instructions(:changed, down_changed))
      |> Enum.concat(generate_instructions(:added, deleted))

    {v2c, [{v1c, up}], [{v1c, down}]}
  end

  defp generate_instructions(:changed, files) do
    files
    |> Enum.map(&generate_instruction(:changed, &1))
    |> topological_sort()
  end

  defp generate_instructions(type, files) do
    Enum.map(files, &generate_instruction(type, &1))
  end

  defp generate_instruction(:added, file), do: {:add_module, module_name(file)}
  defp generate_instruction(:deleted, file), do: {:delete_module, module_name(file)}

  defp generate_instruction(:changed, {v1_file, v2_file}) do
    module_name = module_name(v1_file)
    attributes = beam_attributes(v1_file)
    exports = beam_exports(v1_file)
    imports = beam_imports(v2_file)
    is_supervisor = supervisor?(attributes)
    is_special_proc = special_process?(exports)

    depends_on =
      imports
      |> Enum.map(fn {m, _f, _a} -> m end)
      |> Enum.uniq()

    advanced(module_name, is_supervisor, is_special_proc, depends_on)
  end

  defp beam_attributes(file) do
    {:ok, {_, [attributes: attributes]}} = :beam_lib.chunks(file, [:attributes])
    attributes
  end

  defp beam_imports(file) do
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(file, [:imports])
    imports
  end

  defp beam_exports(file) do
    {:ok, {_, [exports: exports]}} = :beam_lib.chunks(file, [:exports])
    exports
  end

  defp special_process?(exports) do
    Keyword.get(exports, :system_code_change) == 4 ||
      Keyword.get(exports, :code_change) == 3 ||
      Keyword.get(exports, :code_change) == 4
  end

  defp supervisor?(attributes) do
    behaviours =
      Keyword.get(attributes, :behavior, []) ++ Keyword.get(attributes, :behaviour, [])

    :supervisor in behaviours || Supervisor in behaviours
  end

  defp advanced(m, true, _is_special, _deps), do: {:update, m, :supervisor}
  defp advanced(m, _sup, true, []), do: {:update, m, {:advanced, []}}
  defp advanced(m, _sup, true, deps), do: {:update, m, {:advanced, []}, deps}
  defp advanced(m, _sup, false, []), do: {:load_module, m}
  defp advanced(m, _sup, false, deps), do: {:load_module, m, deps}

  # Best-effort topological sort so a module's dependencies load first. The
  # dependency graph is cyclic, so loops are broken by preferring the module
  # with fewer outgoing deps. Verbatim from Distillery.
  defp topological_sort(instructions) do
    mods = Enum.map(instructions, fn i -> elem(i, 1) end)

    instructions
    |> Enum.sort(&sort_instructions(mods, &1, &2))
    |> Enum.map(fn
      {:update, _, _} = i ->
        i

      {:load_module, _} = i ->
        i

      {:update, m, type, deps} ->
        {:update, m, type, Enum.filter(deps, fn d -> d != m and d in mods end)}

      {:load_module, m, deps} ->
        {:load_module, m, Enum.filter(deps, fn d -> d != m and d in mods end)}
    end)
  end

  defp sort_instructions(mods, a, b) do
    am = elem(a, 1)
    bm = elem(b, 1)
    ad = Enum.filter(extract_deps(a), fn d -> d != am and d in mods end)
    bd = Enum.filter(extract_deps(b), fn d -> d != bm and d in mods end)
    lad = length(ad)
    lbd = length(bd)

    cond do
      lad == 0 and lbd != 0 -> true
      lad != 0 and lbd == 0 -> false
      am in bd and bm not in ad -> true
      am not in bd and bm in ad -> false
      lad > lbd -> false
      lbd > lad -> true
      :else -> true
    end
  end

  defp extract_deps({:update, _m, deps}) when is_list(deps), do: deps
  defp extract_deps({:update, _m, _change}), do: []
  defp extract_deps({:update, _m, _change, deps}), do: deps
  defp extract_deps({:load_module, _m, deps}), do: deps
  defp extract_deps(_), do: []

  defp module_name(file), do: Keyword.fetch!(:beam_lib.info(file), :module)

  defp vsn(props) do
    {:value, {:vsn, vsn}} = :lists.keysearch(:vsn, 1, props)
    List.to_string(vsn)
  end
end
