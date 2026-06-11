defmodule Cayennex.SupervisorsTest do
  use ExUnit.Case, async: true

  alias Cayennex.Supervisors

  # A trivial worker so child specs have something real to start.
  defmodule Worker do
    use GenServer
    def start_link(id), do: GenServer.start_link(__MODULE__, id)
    @impl true
    def init(id), do: {:ok, id}
  end

  # A supervisor whose child list is read from :persistent_term, so a test can
  # change what `init/1` returns AFTER the supervisor has booted — exactly the
  # situation a hot upgrade creates (new init/1 code loaded, old children
  # running).
  defmodule DynSup do
    use Supervisor
    def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      ids = :persistent_term.get({__MODULE__, :children})
      children = Enum.map(ids, fn id -> %{id: id, start: {Worker, :start_link, [id]}} end)
      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  setup do
    :persistent_term.put({DynSup, :children}, [:a])
    start_supervised!(DynSup)
    on_exit(fn -> :persistent_term.erase({DynSup, :children}) end)
    :ok
  end

  defp child_pids do
    DynSup |> Supervisor.which_children() |> Map.new(fn {id, pid, _, _} -> {id, pid} end)
  end

  test "starts a child newly added to init/1, leaves the existing one untouched" do
    %{a: pid_a} = child_pids()

    # Simulate the hot upgrade: new init/1 code now returns an extra child.
    :persistent_term.put({DynSup, :children}, [:a, :b])

    assert [{DynSup, summary}] = Supervisors.reconcile([{DynSup, DynSup, :ok}])
    assert summary.started == [:b]
    assert summary.errors == []

    pids = child_pids()
    assert is_pid(pids[:b]), "newly-added child :b should be running"
    assert pids[:a] == pid_a, "existing child :a must not be restarted"
  end

  test "is idempotent — a second reconcile starts nothing" do
    :persistent_term.put({DynSup, :children}, [:a, :b])

    assert [{DynSup, %{started: [:b]}}] = Supervisors.reconcile([{DynSup, DynSup, :ok}])
    assert [{DynSup, %{started: []}}] = Supervisors.reconcile([{DynSup, DynSup, :ok}])

    # exactly one :b, no duplicate
    assert DynSup |> Supervisor.which_children() |> Enum.count(fn {id, _, _, _} -> id == :b end) ==
             1
  end

  test "no-op when init/1 adds nothing" do
    assert [{DynSup, %{started: [], errors: []}}] = Supervisors.reconcile([{DynSup, DynSup, :ok}])
  end

  test "does NOT start (or resurrect) children removed from init/1 — add-only" do
    %{a: pid_a} = child_pids()
    :persistent_term.put({DynSup, :children}, [])

    assert [{DynSup, summary}] = Supervisors.reconcile([{DynSup, DynSup, :ok}])
    assert summary.started == []
    assert summary.removed_kept == [:a], "removed child reported but not terminated"
    # the still-running :a is left exactly as it was
    assert child_pids()[:a] == pid_a
  end

  test "prune: true terminates and deletes a child removed from init/1" do
    %{a: pid_a} = child_pids()
    :persistent_term.put({DynSup, :children}, [:b])

    assert [{DynSup, summary}] = Supervisors.reconcile([{DynSup, DynSup, :ok, prune: true}])
    assert summary.started == [:b]
    assert summary.pruned == [:a]
    assert summary.removed_kept == []
    assert summary.errors == []

    # :a is gone for good — not running and the spec is deleted (no restart slot)
    refute Process.alive?(pid_a)
    ids = DynSup |> Supervisor.which_children() |> Enum.map(fn {id, _, _, _} -> id end)
    assert ids == [:b]
  end

  test "prune adds and removes in the same reconcile" do
    :persistent_term.put({DynSup, :children}, [:a, :b])
    Supervisors.reconcile([{DynSup, DynSup, :ok, prune: true}])

    # next release: drops :a, keeps :b, adds :c
    :persistent_term.put({DynSup, :children}, [:b, :c])

    assert [{DynSup, summary}] = Supervisors.reconcile([{DynSup, DynSup, :ok, prune: true}])
    assert summary.started == [:c]
    assert summary.pruned == [:a]

    ids = DynSup |> Supervisor.which_children() |> Enum.map(fn {id, _, _, _} -> id end)
    assert Enum.sort(ids) == [:b, :c]
  end

  test "prune is idempotent — a second reconcile prunes nothing" do
    :persistent_term.put({DynSup, :children}, [])

    assert [{DynSup, %{pruned: [:a]}}] =
             Supervisors.reconcile([{DynSup, DynSup, :ok, prune: true}])

    assert [{DynSup, %{pruned: [], removed_kept: []}}] =
             Supervisors.reconcile([{DynSup, DynSup, :ok, prune: true}])
  end

  test "bare-module config entry defaults the init arg to :ok" do
    :persistent_term.put({DynSup, :children}, [:a, :b])
    assert [{DynSup, %{started: [:b]}}] = Supervisors.reconcile([DynSup])
  end

  test "reports a hard error for an unreachable supervisor" do
    assert [{:no_such_sup, {:error, {:supervisor_unreachable, :no_such_sup, _}}}] =
             Supervisors.reconcile([{:no_such_sup, DynSup, :ok}])
  end

  test "empty config is a no-op" do
    assert Supervisors.reconcile([]) == []
  end
end
