defmodule Cayennex.TarTest do
  use ExUnit.Case, async: false

  alias Cayennex.Tar

  test "build/3 writes a self-excluding, top-level-entry tarball" do
    rel = Path.join(tmp_dir(), "rel")

    # minimal fake mix-release layout
    File.mkdir_p!(Path.join(rel, "bin"))
    File.write!(Path.join([rel, "bin", "fix"]), "#!/bin/sh\n")
    File.mkdir_p!(Path.join([rel, "lib", "fix-1", "ebin"]))
    File.write!(Path.join([rel, "lib", "fix-1", "ebin", "fix.app"]), "{}.\n")
    File.mkdir_p!(Path.join([rel, "releases", "1"]))
    File.write!(Path.join([rel, "releases", "1", "fix.rel"]), "{}.\n")

    assert :ok = Tar.build(rel, :fix, "1")

    tar = Path.join([rel, "releases", "1", "fix.tar.gz"])
    assert File.exists?(tar)

    {:ok, entries} = :erl_tar.table(String.to_charlist(tar), [:compressed])
    names = Enum.map(entries, &List.to_string/1)

    # release_handler's erl_tar reader rejects "./"-prefixed paths
    refute Enum.any?(names, &String.starts_with?(&1, "./"))

    # top-level dirs are present
    assert Enum.any?(names, &(&1 == "bin" or String.starts_with?(&1, "bin/")))
    assert Enum.any?(names, &String.starts_with?(&1, "lib/"))
    assert Enum.any?(names, &String.starts_with?(&1, "releases/"))

    # the archive does not contain itself (--exclude=*.tar.gz)
    refute Enum.any?(names, &String.contains?(&1, ".tar.gz"))
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "cayennex-tar-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
