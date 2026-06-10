defmodule Cayennex.Deploy do
  @moduledoc """
  The deploy orchestrator: the build → ship → verify → fallback → migrate state
  machine, ported from the bash `deploy.sh` it replaces, transport-abstracted so
  it can run against production (via your `Cayennex.Transport` impl) or a local
  node in CI (via `Cayennex.Transport.Local`).

  ## Phases

    * `build/1`  — read the deployed version, decide what to build, produce the
      upgrade artifact. NEVER mutates the node. Returns a *plan*.
    * `ship/2`   — the only phase that installs on the node. Returns
      `{:error, :needs_full}` when a hot upgrade is impossible or doesn't take,
      so the caller runs `full_deploy/1`.
    * `full_deploy/1` — build a full release, restart the node, verify, migrate.
    * `migrate/1` — run migrations (idempotent).
    * `run/1`    — the whole sequence in one call.

  Migrations run AFTER the fallback decision on the hot path: a failed migration
  (new code already live and verified) fails the job WITHOUT restarting the node.

  ## Configuration

  Build the `%Cayennex.Deploy{}` struct with your transport + release identity.
  The build steps (`build_upgrade_fun`, `build_full_fun`, `ensure_old_fun`,
  `store_release_fun`) default to shelling out to `mix`/the release store; inject
  them to test the state machine without touching disk or a real node.

  The project's `mix.exs` version must already equal `:version` before a build —
  version stamping (`<base>+<githash>` etc.) is build-environment-specific and
  is the caller's job.
  """

  defstruct transport: nil,
            ctx: nil,
            release_name: nil,
            version: nil,
            project_dir: ".",
            build_dir: nil,
            store_dir: nil,
            mix_env: "prod",
            verify_attempts: 30,
            verify_delay_ms: 2000,
            build_upgrade_fun: nil,
            build_full_fun: nil,
            ensure_old_fun: nil,
            store_release_fun: nil,
            sleep_fun: nil

  @type t :: %__MODULE__{}
  @type plan :: {:noop, nil} | {:hot, Path.t()} | {:fallback, term}

  # --- build ---------------------------------------------------------------

  @doc """
  Decide what to build and produce the artifact. Read-only against the node.
  """
  @spec build(t) :: plan | {:error, term}
  def build(%__MODULE__{} = d) do
    case d.transport.running_version(d.ctx) do
      :down ->
        # Never assume "no version" means "first deploy" — a transient transport
        # failure must not turn into a node-wiping full deploy.
        {:error, :node_unreachable}

      {:error, reason} ->
        {:error, {:running_version, reason}}

      {:ok, old} ->
        build_with_old(d, old)
    end
  end

  defp build_with_old(d, old) do
    cond do
      # Every stamped version is <base>+<githash>; anything else means the node
      # returned something unexpected — don't feed it to the old-release lookup.
      not String.contains?(old, "+") ->
        {:error, {:unexpected_version, old}}

      old == d.version ->
        {:noop, nil}

      true ->
        with {:ok, _old_tar} <- ensure_old(d, old),
             {:ok, tar} <- build_upgrade(d, old) do
          {:hot, tar}
        else
          {:error, reason} -> {:fallback, reason}
        end
    end
  end

  # --- ship ----------------------------------------------------------------

  @doc """
  Install the plan on the node. The ONLY phase that mutates production.
  Returns `{:error, :needs_full}` to request `full_deploy/1`.
  """
  @spec ship(t, plan) :: :ok | {:error, :needs_full}
  def ship(_d, {:noop, _}), do: :ok
  def ship(_d, {:fallback, _}), do: {:error, :needs_full}

  def ship(d, {:hot, tarball}) do
    with :ok <- d.transport.ship(d.ctx, tarball, d.version),
         :ok <- d.transport.install(d.ctx, d.version),
         :ok <- verify(d) do
      store_release(d, tarball)
      :ok
    else
      _ -> {:error, :needs_full}
    end
  end

  # --- full deploy ---------------------------------------------------------

  @doc "Build a full release, install it with a restart, verify, migrate."
  @spec full_deploy(t) :: :ok | {:error, term}
  def full_deploy(d) do
    with {:ok, tar} <- build_full(d),
         :ok <- d.transport.full_deploy(d.ctx, tar, d.version),
         :ok <- verify(d),
         :ok <- d.transport.migrate(d.ctx) do
      store_release(d, tar)
      :ok
    end
  end

  # --- migrate -------------------------------------------------------------

  @doc "Run migrations on the node (idempotent)."
  @spec migrate(t) :: :ok | {:error, term}
  def migrate(d), do: d.transport.migrate(d.ctx)

  # --- run (whole pipeline) ------------------------------------------------

  @doc """
  build → ship → (on failure) full_deploy, then migrate on the hot/noop path
  (full_deploy migrates internally).
  """
  @spec run(t) :: :ok | {:error, term}
  def run(d) do
    case build(d) do
      {:error, _} = err ->
        err

      plan ->
        case ship(d, plan) do
          :ok -> migrate(d)
          {:error, :needs_full} -> full_deploy(d)
        end
    end
  end

  # --- verify --------------------------------------------------------------

  @doc "Poll the node until it reports `:version`, or time out."
  @spec verify(t) :: :ok | {:error, :verify_timeout}
  def verify(d), do: do_verify(d, d.verify_attempts)

  defp do_verify(_d, n) when n <= 0, do: {:error, :verify_timeout}

  defp do_verify(d, n) do
    if d.transport.running_version(d.ctx) == {:ok, d.version} do
      :ok
    else
      sleep(d, d.verify_delay_ms)
      do_verify(d, n - 1)
    end
  end

  # --- build-step defaults (injectable) ------------------------------------

  defp ensure_old(%{ensure_old_fun: f}, old) when is_function(f, 1), do: f.(old)

  defp ensure_old(d, old) do
    tar = Path.join(d.store_dir, "#{d.release_name}-#{old}.tar.gz")
    if File.exists?(tar), do: {:ok, tar}, else: {:error, {:old_release_missing, old}}
  end

  defp build_upgrade(%{build_upgrade_fun: f}, old) when is_function(f, 1), do: f.(old)

  defp build_upgrade(d, old) do
    old_tar = Path.join(d.store_dir, "#{d.release_name}-#{old}.tar.gz")

    with :ok <- mix(d, ["release.hot", "--upfrom=#{old}", "--old-tarball=#{old_tar}"]),
         tar = release_tar(d),
         true <- File.exists?(tar) do
      {:ok, tar}
    else
      false -> {:error, :upgrade_tar_missing}
      {:error, _} = err -> err
    end
  end

  defp build_full(%{build_full_fun: f}) when is_function(f, 0), do: f.()

  defp build_full(d) do
    with :ok <- mix(d, ["release", "#{d.release_name}", "--overwrite"]),
         tar = release_tar(d),
         true <- File.exists?(tar) do
      {:ok, tar}
    else
      false -> {:error, :release_tar_missing}
      {:error, _} = err -> err
    end
  end

  defp release_tar(d) do
    Path.join([d.build_dir, "releases", d.version, "#{d.release_name}.tar.gz"])
  end

  defp mix(d, args) do
    case System.cmd("mix", args,
           cd: d.project_dir,
           env: [{"MIX_ENV", d.mix_env}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:mix_failed, args, code, out}}
    end
  end

  # --- release store -------------------------------------------------------

  defp store_release(%{store_release_fun: f}, tar) when is_function(f, 1), do: f.(tar)

  defp store_release(d, tar) do
    # Best-effort: the store is only a fast-path cache for the next deploy's
    # ensure_old. A failure here must NEVER fail an already-verified deploy.
    try do
      File.mkdir_p!(d.store_dir)
      dest = Path.join(d.store_dir, "#{d.release_name}-#{d.version}.tar.gz")
      tmp = dest <> ".tmp"
      File.cp!(tar, tmp)
      File.rename!(tmp, dest)
      prune_store(d)
    rescue
      _ -> :ok
    end

    :ok
  end

  # Keep the newest 5 full-release tarballs; sweep temp leftovers.
  defp prune_store(d) do
    pattern = Path.join(d.store_dir, "#{d.release_name}-*.tar.gz")

    pattern
    |> Path.wildcard()
    |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
    |> Enum.drop(5)
    |> Enum.each(&File.rm/1)

    Path.wildcard(Path.join(d.store_dir, "*.tar.gz.tmp")) |> Enum.each(&File.rm/1)
  end

  defp sleep(%{sleep_fun: f}, ms) when is_function(f, 1), do: f.(ms)
  defp sleep(_d, ms), do: Process.sleep(ms)
end
