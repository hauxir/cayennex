defmodule Cayennex.DeployTest do
  use ExUnit.Case, async: true

  alias Cayennex.Deploy

  # A transport backed by an Agent that simulates the node's observable state.
  defmodule FakeTransport do
    @behaviour Cayennex.Transport

    @impl true
    def running_version(agent) do
      Agent.get(agent, fn s -> if s.down, do: :down, else: {:ok, s.version} end)
    end

    @impl true
    def ship(agent, _tarball, version) do
      Agent.update(agent, fn s -> %{s | shipped: [version | s.shipped]} end)
      :ok
    end

    @impl true
    def install(agent, version) do
      Agent.update(agent, fn s ->
        s = %{s | installs: [version | s.installs]}
        if s.install_takes, do: %{s | version: version}, else: s
      end)

      :ok
    end

    @impl true
    def full_deploy(agent, _tarball, version) do
      Agent.update(agent, fn s ->
        %{s | full_deploys: s.full_deploys + 1, version: version}
      end)

      :ok
    end

    @impl true
    def migrate(agent) do
      Agent.update(agent, fn s -> %{s | migrated: s.migrated + 1} end)
      :ok
    end
  end

  @new "1.0.0+new"

  defp node_agent(attrs \\ %{}) do
    base = %{
      version: "1.0.0+old",
      down: false,
      install_takes: true,
      shipped: [],
      installs: [],
      full_deploys: 0,
      migrated: 0
    }

    {:ok, pid} = Agent.start_link(fn -> Map.merge(base, Map.new(attrs)) end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp state(agent), do: Agent.get(agent, & &1)

  defp config(agent, overrides \\ []) do
    base = %Deploy{
      transport: FakeTransport,
      ctx: agent,
      release_name: :fix,
      version: @new,
      store_dir: "/unused",
      build_dir: "/unused",
      verify_attempts: 3,
      verify_delay_ms: 0,
      sleep_fun: fn _ -> :ok end,
      # inject build/store hooks so no real mix or disk is touched
      ensure_old_fun: fn _old -> {:ok, "/fake/old.tar.gz"} end,
      build_upgrade_fun: fn _old -> {:ok, "/fake/upgrade.tar.gz"} end,
      build_full_fun: fn -> {:ok, "/fake/full.tar.gz"} end,
      store_release_fun: fn _tar -> :ok end
    }

    struct(base, overrides)
  end

  test "noop when the deployed version already matches" do
    agent = node_agent(%{version: @new})
    d = config(agent)

    assert {:noop, nil} = Deploy.build(d)
    assert :ok = Deploy.run(d)

    s = state(agent)
    assert s.installs == []
    assert s.full_deploys == 0
    # a re-run still migrates, so a failed migration after a prior deploy retries
    assert s.migrated == 1
  end

  test "happy path: hot upgrade installs, verifies, and migrates without a restart" do
    agent = node_agent()
    d = config(agent)

    assert {:hot, "/fake/upgrade.tar.gz"} = Deploy.build(d)
    assert :ok = Deploy.run(d)

    s = state(agent)
    assert s.version == @new
    assert s.shipped == [@new]
    assert s.installs == [@new]
    assert s.full_deploys == 0
    assert s.migrated == 1
  end

  test "install that doesn't take falls back to a full deploy" do
    agent = node_agent(%{install_takes: false})
    d = config(agent)

    # build still produces a hot plan; the failure is detected at verify time
    assert {:hot, _} = Deploy.build(d)
    assert :ok = Deploy.run(d)

    s = state(agent)
    assert s.installs == [@new], "it attempted the hot install first"
    assert s.full_deploys == 1, "then fell back to a restart"
    assert s.version == @new
  end

  test "refuses to deploy (no guess) when the node is unreachable" do
    agent = node_agent(%{down: true})
    d = config(agent)

    assert {:error, :node_unreachable} = Deploy.build(d)
    assert {:error, :node_unreachable} = Deploy.run(d)

    s = state(agent)
    assert s.installs == []
    assert s.full_deploys == 0
  end

  test "rejects an unexpected (unstamped) version from the node" do
    agent = node_agent(%{version: "garbage"})
    d = config(agent)

    assert {:error, {:unexpected_version, "garbage"}} = Deploy.build(d)
  end

  test "missing old release → fallback (no relup base to build from)" do
    agent = node_agent()
    d = config(agent, ensure_old_fun: fn old -> {:error, {:old_release_missing, old}} end)

    assert {:fallback, {:old_release_missing, "1.0.0+old"}} = Deploy.build(d)
    assert :ok = Deploy.run(d)
    assert state(agent).full_deploys == 1
  end

  test "upgrade build failure → fallback" do
    agent = node_agent()
    d = config(agent, build_upgrade_fun: fn _old -> {:error, :relup_boom} end)

    assert {:fallback, :relup_boom} = Deploy.build(d)
    assert :ok = Deploy.run(d)
    assert state(agent).full_deploys == 1
  end

  test "verify/1 times out when the node never reports the new version" do
    agent = node_agent(%{install_takes: false})
    d = config(agent)

    assert {:error, :verify_timeout} = Deploy.verify(d)
  end
end
