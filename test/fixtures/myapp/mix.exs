defmodule Myapp.MixProject do
  use Mix.Project

  # Version + the Counter label are stamped via env vars at build time so the
  # E2E test can produce two genuinely-different releases without a VCS.
  def project do
    [
      app: :myapp,
      version: System.get_env("MYAPP_VSN") || "0.1.0+dev",
      elixir: "~> 1.16",
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [mod: {Myapp.Application, []}, extra_applications: [:logger, :sasl]]
  end

  defp deps do
    [{:cayennex, path: "../../.."}, {:depapp, path: "../depapp"}]
  end

  defp releases do
    [
      myapp: [
        include_erts: true,
        applications: [sasl: :permanent],
        steps: [:assemble, &Cayennex.Steps.finalize/1]
      ]
    ]
  end
end
