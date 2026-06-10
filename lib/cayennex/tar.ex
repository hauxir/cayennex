defmodule Cayennex.Tar do
  @moduledoc """
  Packages an assembled mix-release directory into
  `releases/<vsn>/<name>.tar.gz` — the artifact you ship, and the path
  `:release_handler.unpack_release(~c"<vsn>/<name>")` reads on the running node.

  It tars the COMPLETE release directory (bin/, lib/, erts-*, releases/) rather
  than using `:systools.make_tar`, because one tarball must serve three masters:
    * a full deploy extracts it and boots via `bin/<name>` (needs the
      mix-release extras: bin/, env.sh, runtime.exs, ...);
    * a restart after a hot upgrade boots the new version's
      `releases/<vsn>/{env.sh,runtime.exs,boot}` (also mix-release extras);
    * `:release_handler.unpack_release` reads `lib/<app>-<vsn>` +
      `releases/<vsn>` (incl. relup) out of it.
  `:systools.make_tar` omits the mix-release extras, so a whole-dir tar is the
  faithful equivalent.
  """

  @doc """
  Build `releases/<vsn>/<name>.tar.gz` inside `release_dir`. If a `relup`
  exists at `releases/<vsn>/relup` it is included (upgrade tarball); otherwise
  it's a full-release tarball. Re-runnable (the upgrade build calls it twice).
  """
  @spec build(String.t(), atom, String.t()) :: :ok | {:error, term}
  def build(release_dir, name, vsn) do
    target_rel = Path.join(["releases", vsn, "#{name}.tar.gz"])
    target_abs = Path.join(release_dir, target_rel)
    File.mkdir_p!(Path.dirname(target_abs))

    # Tar into a temp file OUTSIDE the dir so we don't recursively include the
    # archive being written. Pass top-level entries (not "."): release_handler's
    # erl_tar reader rejects "./"-prefixed paths.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "#{name}-#{vsn}-#{System.unique_integer([:positive])}.tar.gz"
      )

    entries = release_dir |> File.ls!() |> Enum.sort()

    args = ["czf", tmp, "--exclude=*.tar.gz" | entries]

    try do
      case System.cmd("tar", args, cd: release_dir, stderr_to_stdout: true) do
        {_, 0} ->
          File.cp!(tmp, target_abs)
          :ok

        {out, code} ->
          {:error, {:tar_failed, code, out}}
      end
    after
      File.rm(tmp)
    end
  end
end
