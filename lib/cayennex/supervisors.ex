defmodule Cayennex.Supervisors do
  @moduledoc """
  Runtime supervision-tree reconciliation for hot upgrades.

  cayennex hot-loads new *code*, but it deliberately strips the
  `suspend`/`code_change`/`resume` dance from the relup
  (`Cayennex.Relup.harden/1`). A side effect: OTP never re-runs a supervisor's
  `init/1` during the upgrade, so a child you *add* to a (root) supervisor
  between releases is compiled and loaded onto the node but never **started** —
  `init/1` already ran at boot and the running supervisor is left untouched. The
  upgrade installs green and the new service simply isn't there.

  This module closes that gap, entirely at runtime. After an install,
  `reconcile/0` walks the supervisors named in config and, for each one:

    1. calls its (now hot-loaded) `init/1` to get the **desired** child specs;
    2. reads the children **actually running** via `Supervisor.which_children/1`;
    3. `Supervisor.start_child/2`s every desired child whose id isn't running;
    4. (only when that supervisor opted in to `prune: true`)
       `Supervisor.terminate_child/2` + `Supervisor.delete_child/2`s every
       running child the new `init/1` no longer lists.

  **Add is the default; prune is opt-in.** Starting a brand-new service is safe;
  *terminating* a live one — which on this kind of node may hold the very
  connections a restart would drop — is not, so it never happens unless you ask
  for it per supervisor. Without `prune: true`, removed children are left running
  and merely reported (`removed_kept`). With it, they're terminated and deleted,
  and any failure to do so is surfaced as an error (never fatal — same contract
  as the rest of the install).

  ## Configuration

      config :cayennex, :supervisors, [
        # registered name IS the callback module, init_arg defaults to :ok
        Myapp.RootSupervisor,
        # registered name IS the callback module, explicit init_arg
        {Myapp.RootSupervisor, :ok},
        # registered name differs from the callback module
        {MyName, Myapp.RootSupervisor, :ok},
        # opt in to pruning children dropped from init/1 (add-only otherwise)
        {Myapp.RootSupervisor, Myapp.RootSupervisor, :ok, prune: true}
      ]

  The `init_arg` MUST be the same value you pass to `Supervisor.start_link/3`,
  because that's what `init/1` turns into the child list. If your `init/1`
  ignores its argument (the common case), any value works.

  `opts` is a keyword list; the only key today is `prune: boolean` (default
  `false`). It's the 4th positional element, so pruning requires the full
  `{name, mod, arg, opts}` form.

  Reconciliation only knows how to consult a supervisor whose child list comes
  from `Module.init/1` — i.e. a `use Supervisor` (or `:supervisor` behaviour)
  module. An inline `Supervisor.start_link([...], ...)` in your `Application`
  has no callback module to re-consult; give those a named supervisor module if
  you want new children injected on the hot path.
  """

  @type name :: atom
  @type entry ::
          module | {name, term} | {name, module, term} | {name, module, term, keyword}
  @type result ::
          {name,
           %{started: [term], pruned: [term], removed_kept: [term], errors: [{term, term}]}}
          | {name, {:error, term}}

  @doc """
  Reconcile every supervisor named in `config :cayennex, :supervisors`.
  Returns one `t:result/0` per configured entry. A no-op (returns `[]`) when
  nothing is configured.
  """
  @spec reconcile() :: [result]
  def reconcile, do: reconcile(Application.get_env(:cayennex, :supervisors, []))

  @doc "Reconcile a specific list of supervisor entries. See moduledoc for the entry shapes."
  @spec reconcile([entry]) :: [result]
  def reconcile(entries) when is_list(entries) do
    Enum.map(entries, fn entry -> reconcile_one(normalize(entry)) end)
  end

  defp normalize(mod) when is_atom(mod), do: {mod, mod, :ok, []}
  defp normalize({name_mod, arg}) when is_atom(name_mod), do: {name_mod, name_mod, arg, []}
  defp normalize({name, mod, arg}) when is_atom(name) and is_atom(mod), do: {name, mod, arg, []}

  defp normalize({name, mod, arg, opts})
       when is_atom(name) and is_atom(mod) and is_list(opts),
       do: {name, mod, arg, opts}

  defp reconcile_one({name, mod, arg, opts}) do
    with {:ok, desired} <- desired_specs(mod, arg),
         {:ok, live_ids} <- live_ids(name) do
      desired_ids = MapSet.new(desired, &spec_id/1)
      additions = Enum.reject(desired, fn spec -> spec_id(spec) in live_ids end)
      removed_ids = Enum.reject(MapSet.to_list(live_ids), &MapSet.member?(desired_ids, &1))

      add_results = Enum.map(additions, fn spec -> {spec_id(spec), start_child(name, spec)} end)

      {started, add_errors} =
        Enum.split_with(add_results, fn {_id, r} -> r in [:started, :already_running] end)

      {pruned, removed_kept, prune_errors} = prune(name, removed_ids, opts)

      {name,
       %{
         started: Enum.map(started, &elem(&1, 0)),
         # running children the new init/1 no longer lists, terminated+deleted
         # (only when this supervisor opted in to prune: true).
         pruned: pruned,
         # ...left running and merely reported when prune is off — see moduledoc.
         removed_kept: removed_kept,
         errors: Enum.map(add_errors ++ prune_errors, fn {id, {:error, reason}} -> {id, reason} end)
       }}
    else
      {:error, reason} -> {name, {:error, reason}}
    end
  end

  # Add-only by default: report removed children but leave them running. With
  # prune: true, terminate+delete each; failures become errors, never fatal.
  defp prune(name, removed_ids, opts) do
    if Keyword.get(opts, :prune, false) do
      results = Enum.map(removed_ids, fn id -> {id, prune_child(name, id)} end)
      {ok, errored} = Enum.split_with(results, fn {_id, r} -> r == :pruned end)
      {Enum.map(ok, &elem(&1, 0)), [], errored}
    else
      {[], removed_ids, []}
    end
  end

  defp prune_child(name, id) do
    with :ok <- Supervisor.terminate_child(name, id),
         :ok <- Supervisor.delete_child(name, id) do
      :pruned
    end
  catch
    :exit, reason -> {:error, {:prune_exit, reason}}
  end

  # Ask the (freshly hot-loaded) callback module what its children should be.
  defp desired_specs(mod, arg) do
    case safe_init(mod, arg) do
      {:ok, {:ok, {_flags, specs}}} when is_list(specs) -> {:ok, specs}
      {:ok, other} -> {:error, {:bad_init_return, mod, other}}
      {:error, _} = err -> err
    end
  end

  defp safe_init(mod, arg) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :init, 1) do
      {:ok, mod.init(arg)}
    else
      {:error, {:no_init, mod}}
    end
  rescue
    e -> {:error, {:init_raised, mod, e}}
  end

  defp live_ids(name) do
    ids =
      name
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _child, _type, _mods} -> id end)
      |> MapSet.new()

    {:ok, ids}
  catch
    :exit, reason -> {:error, {:supervisor_unreachable, name, reason}}
  end

  defp start_child(name, spec) do
    case Supervisor.start_child(name, spec) do
      {:ok, _pid} -> :started
      {:ok, _pid, _info} -> :started
      {:error, {:already_started, _pid}} -> :already_running
      {:error, :already_present} -> :already_running
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:start_child_exit, reason}}
  end

  defp spec_id(%{id: id}), do: id
  defp spec_id(tuple) when is_tuple(tuple), do: elem(tuple, 0)
end
