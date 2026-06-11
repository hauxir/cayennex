defmodule Myapp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Myapp.RootSupervisor.start_link([])
  end
end
