defmodule Cayennex.Transport.Local do
  @moduledoc """
  A `Cayennex.Transport` that drives a release running on the SAME host, via its
  `bin/<name>` control script. No SSH, no containers — file copies and local
  `rpc`/`daemon` calls.

  Use it for single-host deploys, and for cayennex's own end-to-end tests (build
  a release, boot it, hot-upgrade it, assert).

  `ctx` is a map:

      %{
        rel_root: "/path/to/running/release",  # holds bin/<name>, releases/, lib/
        name: :my_app,                          # release name (== app name)
        migrate_rpc: nil                        # optional rpc expression string
      }
  """

  @behaviour Cayennex.Transport

  @impl true
  def running_version(%{rel_root: root, name: name}) do
    expr = "IO.puts(List.to_string(Application.spec(:#{name}, :vsn)))"

    case bin(root, name, ["rpc", expr]) do
      {:ok, out} ->
        case String.trim(out) do
          "" -> :down
          v -> {:ok, v}
        end

      {:error, _} ->
        :down
    end
  end

  @impl true
  def ship(%{rel_root: root, name: name}, tarball, version) do
    dest_dir = Path.join([root, "releases", version])

    try do
      File.mkdir_p!(dest_dir)
      File.cp!(tarball, Path.join(dest_dir, "#{name}.tar.gz"))
      :ok
    rescue
      e -> {:error, e}
    end
  end

  @impl true
  def install(%{rel_root: root, name: name}, version) do
    case bin(root, name, ["rpc", ~s|Cayennex.Upgrade.install("#{version}")|]) do
      {:ok, _out} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def full_deploy(%{rel_root: root, name: name}, tarball, _version) do
    # Extract over the release root, then restart. (A bad tarball would corrupt
    # the running release here — a production transport should extract to a
    # staging dir and swap; for same-host/test use this direct path is fine.)
    try do
      File.mkdir_p!(root)
      {_, 0} = System.cmd("tar", ["xzf", tarball, "-C", root])
      _ = bin(root, name, ["stop"])
      wait_down(root, name)

      case bin(root, name, ["daemon"]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl true
  def migrate(%{rel_root: root, name: name} = ctx) do
    case Map.get(ctx, :migrate_rpc) do
      nil ->
        :ok

      expr ->
        case bin(root, name, ["rpc", expr]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # --- helpers -------------------------------------------------------------

  defp bin(root, name, args) do
    exe = Path.join([root, "bin", "#{name}"])

    case System.cmd(exe, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:bin_failed, args, code, out}}
    end
  rescue
    e -> {:error, e}
  end

  # `bin stop` returns before the node is fully down; give it a moment so the
  # subsequent `daemon` doesn't collide on the node name.
  defp wait_down(root, name, attempts \\ 20)
  defp wait_down(_root, _name, 0), do: :ok

  defp wait_down(root, name, n) do
    case bin(root, name, ["pid"]) do
      {:ok, out} ->
        if String.trim(out) == "" do
          :ok
        else
          Process.sleep(100)
          wait_down(root, name, n - 1)
        end

      {:error, _} ->
        :ok
    end
  end
end
