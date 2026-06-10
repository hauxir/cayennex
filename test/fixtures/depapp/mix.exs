defmodule Depapp.MixProject do
  use Mix.Project

  # Version is stamped via DEPAPP_VSN so the E2E test can ship two versions of
  # this dependency and prove a dep hot-upgrades (not just the top app).
  def project do
    [
      app: :depapp,
      version: System.get_env("DEPAPP_VSN") || "0.1.0",
      elixir: "~> 1.16"
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
