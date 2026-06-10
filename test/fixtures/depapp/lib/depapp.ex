defmodule Depapp do
  @moduledoc """
  A dependency of the `myapp` fixture. The E2E test rewrites `tag/0` and bumps
  this app's version between releases to prove that a *dependency* application
  hot-upgrades on the running node — the thing plain code-loading can't do.
  """

  def tag, do: :v1
end
