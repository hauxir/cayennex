defmodule Cayennex.HotUpgradeE2ETest do
  @moduledoc """
  End-to-end: build a real release of the `myapp` fixture, boot it as a daemon,
  accumulate state, then drive a hot upgrade through `Cayennex.Deploy` +
  `Cayennex.Transport.Local` and assert the running node picked up new code —
  both the app's own code AND a bumped dependency — WITHOUT losing the
  GenServer's state or restarting.
  """
  use ExUnit.Case, async: false

  @moduletag :e2e
  # building + booting releases is slow
  @moduletag timeout: 600_000

  alias Cayennex.Deploy
  alias Cayennex.Transport.Local

  @fixture Path.expand("../fixtures/myapp", __DIR__)
  @counter Path.join(@fixture, "lib/myapp/counter.ex")
  @depapp Path.expand("../fixtures/depapp/lib/depapp.ex", __DIR__)

  @v1 "0.1.0+a1"
  @v2 "0.1.0+a2"
  @dep_v1 "0.1.0"
  @dep_v2 "0.2.0"

  setup do
    # Unique node name per run so a leaked daemon from a prior run can't be
    # reached by our `bin rpc` calls. Inherited by every System.cmd below
    # (helpers AND Cayennex.Transport.Local, which run in this VM's env).
    System.put_env("MYAPP_NODE", "myapp-#{System.unique_integer([:positive])}@127.0.0.1")

    counter0 = File.read!(@counter)
    depapp0 = File.read!(@depapp)
    work = tmp_dir()
    store = Path.join(work, "store")
    rel_root = Path.join(work, "run")
    File.mkdir_p!(store)
    File.mkdir_p!(rel_root)

    on_exit(fn ->
      _ = bin(rel_root, ["stop"])
      File.write!(@counter, counter0)
      File.write!(@depapp, depapp0)
      File.rm_rf(work)
    end)

    %{store: store, rel_root: rel_root, build_dir: build_dir()}
  end

  test "hot upgrade: app code + a bumped dependency go live, state survives, no restart",
       ctx do
    # --- v1: build, extract, boot -----------------------------------------
    set_label("v1")
    set_dep_tag("v1")
    clean_build()
    build_release(@v1, @dep_v1)
    v1_tar = release_tar(@v1)
    File.cp!(v1_tar, Path.join(ctx.store, "myapp-#{@v1}.tar.gz"))
    extract(v1_tar, ctx.rel_root)

    {_, 0} = bin(ctx.rel_root, ["daemon"])
    wait_until_up(ctx.rel_root)

    # accumulate state and confirm we're on v1 (app + dep)
    Enum.each(1..3, fn _ -> {_, 0} = bin(ctx.rel_root, ["rpc", "Myapp.Counter.bump()"]) end)
    assert rpc(ctx.rel_root, "Myapp.Counter.get()") == "3"
    assert rpc(ctx.rel_root, "Myapp.Counter.label()") == "v1"
    assert rpc(ctx.rel_root, "Myapp.Counter.dep_tag()") == "v1"
    assert running_version(ctx.rel_root) == @v1

    # --- v2: change app code + bump the dependency, drive the upgrade ------
    set_label("v2")
    set_dep_tag("v2")
    System.put_env("MYAPP_VSN", @v2)
    System.put_env("DEPAPP_VSN", @dep_v2)
    # Clean build so the v2 release.hot stamps the right version and recompiles
    # every changed source — the old release comes from the store tarball, not
    # _build, so the relup base is unaffected.
    clean_build()

    deploy = %Deploy{
      transport: Local,
      ctx: %{rel_root: ctx.rel_root, name: :myapp},
      release_name: :myapp,
      version: @v2,
      project_dir: @fixture,
      build_dir: ctx.build_dir,
      store_dir: ctx.store,
      mix_env: "prod",
      verify_attempts: 30,
      verify_delay_ms: 1000
    }

    assert :ok = Deploy.run(deploy)

    # --- assert: app + dep code live, state survived, version flipped ------
    assert running_version(ctx.rel_root) == @v2, "node should report the new version"
    assert rpc(ctx.rel_root, "Myapp.Counter.label()") == "v2", "app's new code is live"
    assert rpc(ctx.rel_root, "Myapp.Counter.dep_tag()") == "v2", "dependency hot-upgraded"
    assert rpc(ctx.rel_root, "Myapp.Counter.get()") == "3", "state survived the upgrade"
  end

  # --- helpers -------------------------------------------------------------

  defp set_label(label) do
    rewrite(@counter, ~r/@label "[^"]*"/, ~s|@label "#{label}"|)
  end

  defp set_dep_tag(tag) do
    rewrite(@depapp, ~r/def tag, do: :\w+/, "def tag, do: :#{tag}")
  end

  defp rewrite(path, pattern, replacement) do
    File.write!(path, String.replace(File.read!(path), pattern, replacement))
  end

  defp build_release(vsn, dep_vsn) do
    System.put_env("MYAPP_VSN", vsn)
    System.put_env("DEPAPP_VSN", dep_vsn)
    {out, code} = mix(["release", "myapp", "--overwrite"])
    assert code == 0, "mix release #{vsn} failed:\n#{out}"
  end

  # Build each version from a clean slate: the version is stamped via an env var
  # that mix's incremental compiler doesn't track, so a stale _build would
  # produce the wrong version / stale modules.
  defp clean_build, do: File.rm_rf!(Path.join(@fixture, "_build/prod"))

  defp build_dir, do: Path.join(@fixture, "_build/prod/rel/myapp")
  defp release_tar(vsn), do: Path.join([build_dir(), "releases", vsn, "myapp.tar.gz"])

  defp extract(tar, dest) do
    {_, 0} = System.cmd("tar", ["xzf", tar, "-C", dest])
  end

  defp mix(args) do
    System.cmd("mix", args, cd: @fixture, env: [{"MIX_ENV", "prod"}], stderr_to_stdout: true)
  end

  defp bin(rel_root, args) do
    System.cmd(Path.join([rel_root, "bin", "myapp"]), args, stderr_to_stdout: true)
  end

  defp rpc(rel_root, expr) do
    {out, 0} = bin(rel_root, ["rpc", "IO.puts(#{expr})"])
    String.trim(out)
  end

  defp running_version(rel_root) do
    case Local.running_version(%{rel_root: rel_root, name: :myapp}) do
      {:ok, v} -> v
      other -> other
    end
  end

  defp wait_until_up(rel_root, attempts \\ 60)
  defp wait_until_up(_rel_root, 0), do: flunk("daemon never came up")

  defp wait_until_up(rel_root, n) do
    case Local.running_version(%{rel_root: rel_root, name: :myapp}) do
      {:ok, _} -> :ok
      _ -> Process.sleep(500) && wait_until_up(rel_root, n - 1)
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cayennex-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
