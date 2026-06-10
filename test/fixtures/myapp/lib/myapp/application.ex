defmodule Myapp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Myapp.Counter], strategy: :one_for_one, name: Myapp.Supervisor)
  end
end
