defmodule Myapp.RootSupervisor do
  @moduledoc """
  The app's root supervisor — a named `use Supervisor` module so cayennex has a
  callback module to re-consult on the hot path.

  The child list is gated on a build-time env var: the E2E test builds v2 with
  `MYAPP_EXTRA_CHILD=1`, so v2's compiled `init/1` lists an extra child
  (`Myapp.Greeter`) that v1's does not, then builds v3 with it off again so v3's
  `init/1` drops that child. A relup loads the new `init/1` code but never
  re-runs it, so on its own the added child would never start (v2) and the
  dropped one would never stop (v3) — which is exactly what `Cayennex.Supervisors`
  reconciles at runtime: starting the addition, and (with `prune: true`)
  terminating the removal.
  """
  use Supervisor

  # Read at COMPILE time, so v1 and v2 ship genuinely different `init/1` code.
  @extra_child System.get_env("MYAPP_EXTRA_CHILD") == "1"

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: Supervisor.init(children(), strategy: :one_for_one)

  defp children do
    if @extra_child, do: [Myapp.Counter, Myapp.Greeter], else: [Myapp.Counter]
  end
end
