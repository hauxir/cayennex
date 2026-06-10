defmodule Cayennex.AppupTest do
  use ExUnit.Case, async: false

  alias Cayennex.Appup

  @app :fixapp

  test "make/5: add_module for new, load_module for changed, nothing for unchanged" do
    tmp = tmp_dir()

    foo_v1 = "defmodule Cayennex.Fix.Foo do\n  def go, do: 1\nend\n"
    foo_v2 = "defmodule Cayennex.Fix.Foo do\n  def go, do: 2\nend\n"
    bar = "defmodule Cayennex.Fix.Bar do\n  def hi, do: :hi\nend\n"
    keep = "defmodule Cayennex.Fix.Keep do\n  def stay, do: :stay\nend\n"

    v1 = build_app(tmp, @app, "1", [foo_v1, keep])
    v2 = build_app(tmp, @app, "2", [foo_v2, bar, keep])

    assert {:ok, {~c"2", [{~c"1", up}], [{~c"1", down}]}} =
             Appup.make(@app, "1", "2", v1, v2)

    # new module added
    assert {:add_module, Cayennex.Fix.Bar} in up

    # changed module is (re)loaded
    assert Enum.any?(up, fn
             {:load_module, Cayennex.Fix.Foo} -> true
             {:load_module, Cayennex.Fix.Foo, _deps} -> true
             _ -> false
           end)

    # unchanged module gets no instruction
    refute Enum.any?(up, fn i ->
             is_tuple(i) and tuple_size(i) >= 2 and elem(i, 1) == Cayennex.Fix.Keep
           end)

    # on downgrade, the added module is deleted
    assert {:delete_module, Cayennex.Fix.Bar} in down
  end

  test "make/5: mismatched declared version is reported, not silently wrong" do
    tmp = tmp_dir()
    foo = "defmodule Cayennex.Fix.Solo do\n  def x, do: 1\nend\n"
    v1 = build_app(tmp, @app, "1", [foo])
    v2 = build_app(tmp, @app, "2", [foo])

    # ask for an upfrom version the v1 .app doesn't declare
    assert {:error, {:mismatched_version, :previous, "9", "1"}} =
             Appup.make(@app, "9", "2", v1, v2)
  end

  # Compile each source to a real .beam in a versioned ebin dir and write a
  # matching .app, so Appup.make reads exactly what a release layout has.
  defp build_app(tmp, app, vsn, sources) do
    path = Path.join(tmp, "#{app}-#{vsn}")
    ebin = Path.join(path, "ebin")
    File.mkdir_p!(ebin)

    modules =
      Enum.map(sources, fn src ->
        [{mod, bin}] = Code.compile_string(src)
        File.write!(Path.join(ebin, "#{mod}.beam"), bin)
        mod
      end)

    app_term =
      {:application, app,
       [
         {:description, ~c"fixture"},
         {:vsn, String.to_charlist(vsn)},
         {:modules, modules},
         {:registered, []},
         {:applications, [:kernel, :stdlib]}
       ]}

    File.write!(Path.join(ebin, "#{app}.app"), :io_lib.format(~c"~p.~n", [app_term]))
    path
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "cayennex-appup-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
