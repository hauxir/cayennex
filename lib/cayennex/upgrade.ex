defmodule Cayennex.Upgrade do
  @moduledoc """
  Installs a hot upgrade on the RUNNING node. Invoke it via the release's rpc:

      bin/<release> rpc 'Cayennex.Upgrade.install("<vsn>")'

  so it runs *inside* the live BEAM. It NEVER halts/crashes the node: it returns
  `:ok` / `{:error, reason}` and prints a greppable marker. Your deploy script's
  post-install version check should be the source of truth and trigger a
  full-deploy fallback when an install doesn't take.

  The release name defaults to the `RELEASE_NAME` env var (set by the mix
  release boot scripts); pass it explicitly via `install/2` otherwise.

  Expects the upgrade tarball already shipped to
  `$RELEASE_ROOT/releases/<vsn>/<name>.tar.gz`.

  Ported from `Distillery.Releases.Runtime.Control.install/2`, but with no peer
  (we're already on the node) and never halting.
  """

  @spec install(String.t()) :: :ok | {:error, term}
  def install(version) when is_binary(version), do: install(version, default_name())

  @spec install(String.t(), atom | String.t()) :: :ok | {:error, term}
  def install(version, name) when is_binary(version) do
    app = to_string(name)
    vsn = String.to_charlist(version)
    package = String.to_charlist("#{version}/#{app}")

    case List.keyfind(which_releases(), vsn, 0) do
      nil ->
        log("unpacking releases/#{version}/#{app}.tar.gz")

        case :release_handler.unpack_release(package) do
          {:ok, _} -> install_and_permafy(vsn)
          {:error, reason} -> fail(:unpack, reason)
        end

      {_, status} when status in [:old, :unpacked] ->
        install_and_permafy(vsn)

      {_, :current} ->
        permafy(vsn)

      {_, :permanent} ->
        log("#{version} already permanent")
        :ok
    end
  end

  defp default_name do
    case System.get_env("RELEASE_NAME") do
      nil ->
        raise "RELEASE_NAME is not set; pass the release name explicitly: " <>
                "Cayennex.Upgrade.install(version, name)"

      name ->
        name
    end
  end

  defp install_and_permafy(vsn) do
    case :release_handler.check_install_release(vsn) do
      {:ok, _other, _desc} ->
        case :release_handler.install_release(vsn, update_paths: true) do
          {:ok, _, _} ->
            log("installed #{vsn}")
            permafy(vsn)

          # soft_purge hit a process still running old code; the caller should
          # fall back to a full (restart) deploy.
          {:error, {:old_processes, mod}} ->
            fail(:install, {:old_processes, mod})

          {:error, reason} ->
            fail(:install, reason)
        end

      {:error, reason} ->
        fail(:check_install, reason)
    end
  end

  defp permafy(vsn) do
    case :release_handler.make_permanent(vsn) do
      :ok ->
        log("made #{vsn} permanent")
        :ok

      {:error, reason} ->
        fail(:make_permanent, reason)
    end
  end

  defp which_releases do
    for {_name, vsn, _libs, status} <- :release_handler.which_releases() do
      {String.to_charlist("#{vsn}"), status}
    end
  end

  # Print a clear, greppable marker; never raise/halt (would take down prod).
  defp fail(stage, reason) do
    IO.puts("UPGRADE_FAILED #{stage}: #{inspect(reason)}")
    {:error, {stage, reason}}
  end

  defp log(msg), do: IO.puts("==> #{msg}")
end
