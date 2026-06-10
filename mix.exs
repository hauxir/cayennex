defmodule Cayennex.MixProject do
  use Mix.Project

  def project do
    [
      app: :cayennex,
      version: "0.1.0",
      # 1.20+ for its stronger set-theoretic type checking (surfaced at
      # compile time, which `mix check` treats as warnings-as-errors).
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Naive hot-code upgrades for mix release: load changed code AND changed/new " <>
          "dependency apps onto a live node without a restart — and without the OTP " <>
          "state-migration ceremony."
    ]
  end

  def application do
    # :sasl carries release_handler + systools, which the build-time relup
    # generation and the runtime install both drive.
    [extra_applications: [:logger, :sasl]]
  end

  # `check` runs `test`, so the whole alias must run in the :test env.
  def cli do
    [preferred_envs: [check: :test]]
  end

  # Zero deps on purpose: everything here is plain OTP (:systools, :beam_lib,
  # :release_handler). Keeps the tool self-contained and the CI fast.
  defp deps, do: []

  defp aliases do
    [
      check: [
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "test"
      ]
    ]
  end
end
