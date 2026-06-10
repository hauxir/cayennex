defmodule Mix.Tasks.Release.Hot do
  @shortdoc "Build a hot-upgrade release (relup) from a previous version"
  @moduledoc """
  Builds an upgrade release that hot-upgrades `--upfrom` -> the current version.

      MIX_ENV=prod mix release.hot --upfrom=<old_vsn> --old-tarball=<path>

  Steps:
    1. assemble the new release (`mix release`, which also writes RELEASES + a
       full tarball via `Cayennex.Steps.finalize/1`);
    2. overlay the old release's `lib/<app>-<old>` and `releases/<old>` from
       `--old-tarball` into the build dir (the relup base);
    3. generate `releases/<new>/relup` (`Cayennex.Relup`);
    4. repackage the tarball WITH the relup.

  Produces `_build/<env>/rel/<name>/releases/<new>/<name>.tar.gz`. On
  `{:error, :erts_changed}` it aborts non-zero so a deploy script can fall back
  to a full deploy (relup can't hot-swap ERTS).

  The release name comes from `--name`, else the first release in `mix.exs`,
  else the project's `:app`.
  """
  use Mix.Task

  alias Cayennex.{Relup, Tar}

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [upfrom: :string, old_tarball: :string, name: :string]
      )

    old = opts[:upfrom] || Mix.raise("--upfrom=<old_vsn> is required")
    old_tarball = opts[:old_tarball] || Mix.raise("--old-tarball=<path> is required")
    File.exists?(old_tarball) || Mix.raise("old tarball not found: #{old_tarball}")

    name = (opts[:name] && String.to_atom(opts[:name])) || default_release_name()

    # 1. assemble the new release (runs Steps.finalize → RELEASES + full tar)
    Mix.Task.run("release", ["#{name}", "--overwrite"])

    release_dir = Path.join([Mix.Project.build_path(), "rel", "#{name}"])
    new_vsn = Mix.Project.config()[:version]

    # 2. overlay the old release (lib + releases/<old>) without clobbering the
    #    new release-level files (RELEASES/COOKIE/start_erl.data).
    overlay_old(old_tarball, release_dir, old)

    # 3. relup
    case Relup.generate(release_dir, name, old, new_vsn) do
      :ok ->
        :ok

      {:error, :erts_changed} ->
        Mix.raise("ERTS version changed #{old} -> #{new_vsn}; a full deploy is required")

      {:error, reason} ->
        Mix.raise("relup generation failed: #{inspect(reason)}")
    end

    # 4. repackage with the relup included
    case Tar.build(release_dir, name, new_vsn) do
      :ok -> Mix.shell().info("Built hot upgrade #{old} -> #{new_vsn}")
      {:error, reason} -> Mix.raise("upgrade tar failed: #{inspect(reason)}")
    end
  end

  defp default_release_name do
    case Mix.Project.config()[:releases] do
      [{name, _opts} | _] ->
        name

      _ ->
        case Mix.Project.config()[:app] do
          nil -> Mix.raise("could not determine release name; pass --name=<release>")
          app -> app
        end
    end
  end

  defp overlay_old(old_tarball, release_dir, old_vsn) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "old-#{old_vsn}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      {_, 0} = System.cmd("tar", ["xzf", Path.expand(old_tarball), "-C", tmp])

      old_lib = Path.join(tmp, "lib")
      old_rel = Path.join([tmp, "releases", old_vsn])

      File.dir?(old_lib) || Mix.raise("old tarball missing lib/: #{old_tarball}")

      File.dir?(old_rel) ||
        Mix.raise("old tarball missing releases/#{old_vsn}: #{old_tarball}")

      # Merge old app versions into the build dir; add the old release dir.
      File.cp_r!(old_lib, Path.join(release_dir, "lib"))
      File.cp_r!(old_rel, Path.join([release_dir, "releases", old_vsn]))
    after
      File.rm_rf(tmp)
    end
  end
end
