defmodule Myapp.Counter do
  @moduledoc """
  A stateful process whose count must survive a hot upgrade. The E2E test
  rewrites the `@label` literal between releases to create a real code change;
  after the upgrade `label/0` must report the new value while `get/0` still
  returns the count accumulated before the upgrade.
  """
  use GenServer

  @label "v1"

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def bump, do: GenServer.call(__MODULE__, :bump)
  def get, do: GenServer.call(__MODULE__, :get)
  def label, do: @label
  # delegates to the dependency so the test can prove the dep's code went live
  def dep_tag, do: Depapp.tag()

  @impl true
  def init(n), do: {:ok, n}

  @impl true
  def handle_call(:bump, _from, n), do: {:reply, n + 1, n + 1}
  def handle_call(:get, _from, n), do: {:reply, n, n}
end
