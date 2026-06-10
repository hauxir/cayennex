defmodule Cayennex.Transport do
  @moduledoc """
  The boundary between cayennex's deploy orchestration (`Cayennex.Deploy`) and
  your infrastructure.

  `Cayennex.Deploy` owns the *decision logic* (build → ship → verify →
  fallback → migrate); a transport teaches it how to actually reach your
  running node. Everything infra-specific — SSH, `docker exec`, bind-mount
  paths, container names — lives behind these callbacks, in *your* repo, not
  here.

  `ctx` is opaque to the orchestrator: it's whatever your transport needs
  (host, container, node name, release root, ...). cayennex ships
  `Cayennex.Transport.Local` for same-host deploys and for its own tests; a
  production transport (e.g. SSH + `docker exec`) is an impl detail you keep
  alongside your app.
  """

  @type ctx :: term
  @type version :: String.t()

  @doc """
  Version running on the node. `:down` means unreachable (the orchestrator
  must NOT treat that as "no version / first deploy" — it refuses to guess).
  """
  @callback running_version(ctx) :: {:ok, version} | :down | {:error, term}

  @doc """
  Place an upgrade tarball where `install/2` can unpack it — i.e. at the node's
  `releases/<version>/<name>.tar.gz`.
  """
  @callback ship(ctx, tarball :: Path.t(), version) :: :ok | {:error, term}

  @doc """
  Run `Cayennex.Upgrade.install(version)` on the node. The orchestrator
  re-verifies the running version regardless of the return value (install never
  halts), so this only needs to surface transport-level failures.
  """
  @callback install(ctx, version) :: :ok | {:error, term}

  @doc "Install a full release and restart the node."
  @callback full_deploy(ctx, tarball :: Path.t(), version) :: :ok | {:error, term}

  @doc "Run migrations on the node (must be idempotent)."
  @callback migrate(ctx) :: :ok | {:error, term}
end
