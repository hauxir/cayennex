defmodule Cayennex.RelupHardenTest do
  use ExUnit.Case, async: true

  alias Cayennex.Relup

  test "brutal_purge becomes soft_purge anywhere in the term" do
    assert Relup.harden({:load, {Foo, :brutal_purge, :brutal_purge, []}}) ==
             {:load, {Foo, :soft_purge, :soft_purge, []}}

    assert Relup.harden([:brutal_purge, :other]) == [:soft_purge, :other]
  end

  test "suspend/resume/code_change instructions are stripped from instruction lists" do
    # Shape of a real relup: {Vsn, [{UpFrom, Descr, Up}], [{DownTo, Descr, Down}]}
    relup =
      {~c"2",
       [
         {~c"1", [],
          [
            {:load_object_code, {:fix, ~c"2", [Foo]}},
            :point_of_no_return,
            {:suspend, [Foo]},
            {:load, {Foo, :brutal_purge, :brutal_purge}},
            {:code_change, [{Foo, []}]},
            {:resume, [Foo]}
          ]}
       ], [{~c"1", [], []}]}

    {_vsn, [{~c"1", [], up}], _down} = Relup.harden(relup)

    refute Enum.any?(up, fn
             t when is_tuple(t) -> elem(t, 0) in [:suspend, :resume, :code_change]
             _ -> false
           end)

    # the structural instructions survive, brutal_purge is softened
    assert :point_of_no_return in up
    assert {:load_object_code, {:fix, ~c"2", [Foo]}} in up
    assert {:load, {Foo, :soft_purge, :soft_purge}} in up
  end

  test "a relup with no special-process instructions is unchanged except purge" do
    relup = {~c"2", [{~c"1", [], [{:load, {Foo, :brutal_purge, :brutal_purge}}]}], []}

    assert Relup.harden(relup) ==
             {~c"2", [{~c"1", [], [{:load, {Foo, :soft_purge, :soft_purge}}]}], []}
  end
end
