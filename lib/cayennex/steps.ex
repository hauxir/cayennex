defmodule Cayennex.Steps do
  @moduledoc """
  A mix release `:steps` callback. `finalize/1` runs after `:assemble` and
  produces the two things `mix release` doesn't emit but a
  `release_handler`-based hot upgrade needs:
    * `releases/RELEASES` — the OTP release index `:release_handler` requires
      (mix release omits it);
    * `releases/<vsn>/<name>.tar.gz` — the ship artifact (see `Cayennex.Tar`).

  Wire it into your release config:

      releases: [
        my_app: [
          include_erts: true,
          applications: [sasl: :permanent],
          steps: [:assemble, &Cayennex.Steps.finalize/1]
        ]
      ]
  """

  alias Cayennex.Tar

  @spec finalize(Mix.Release.t()) :: Mix.Release.t()
  def finalize(release = %Mix.Release{}) do
    write_releases_index(release)

    case Tar.build(release.path, release.name, release.version) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("release tar failed: #{inspect(reason)}")
    end

    release
  end

  defp write_releases_index(release = %Mix.Release{}) do
    root = release.path |> Path.expand()
    releases_dir = Path.join(root, "releases")
    rel_file = Path.join([releases_dir, release.version, "#{release.name}.rel"])

    # create_RELEASES refuses to overwrite; drop any stale index first.
    File.rm(Path.join(releases_dir, "RELEASES"))

    case :release_handler.create_RELEASES(
           String.to_charlist(root),
           String.to_charlist(releases_dir),
           String.to_charlist(rel_file),
           []
         ) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("create_RELEASES failed: #{inspect(reason)}")
    end
  end
end
