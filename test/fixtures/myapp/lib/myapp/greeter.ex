defmodule Myapp.Greeter do
  @moduledoc """
  A service that exists in the codebase but is only wired into the root
  supervisor in v2 (see `Myapp.RootSupervisor`). After a hot upgrade,
  `Cayennex.Supervisors` should start it on the running node without a restart;
  `hello/0` succeeding proves the process is alive.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def hello, do: GenServer.call(__MODULE__, :hello)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call(:hello, _from, state), do: {:reply, :greetings, state}
end
