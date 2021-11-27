defmodule ALF.DSL.ValidationsTest do
  use ExUnit.Case, async: true

  alias ALF.DSLError

  setup do
    sup_pid = Process.whereis(ALF.DynamicSupervisor)
    %{sup_pid: sup_pid}
  end

  describe "Stage validations" do
    test "wrong options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Wrong options for the Elixir.ModuleA stage: [:bla]. " <>
                     "Available options are [:opts, :count, :name]",
                   fn ->
                     defmodule StageWithWrongOptions do
                       use ALF.DSL

                       @components [stage(ModuleA, bla: :bla)]
                     end
                   end
    end

    test "string instead of atom", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Stage must be an atom: \"ModuleA\"",
                   fn ->
                     defmodule StageWithWrongOptions do
                       use ALF.DSL

                       @components [stage("ModuleA")]
                     end
                   end
    end
  end

  describe "Switch" do
    test "required options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Not all the required options are given for the switch switch. " <>
                     "You forgot specifying [:branches]",
                   fn ->
                     defmodule SwitchWithoutRequiredOpts do
                       use ALF.DSL

                       @components [switch(:switch, to: :b)]
                     end
                   end
    end

    test "invalid options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Wrong options for the switch switch: [:foo]. " <>
                     "Available options are [:branches, :opts, :name]",
                   fn ->
                     defmodule SwitchWithWrongOpts do
                       use ALF.DSL

                       @components [switch(:switch, branches: [], foo: :bar)]
                     end
                   end
    end
  end

  describe "Clone" do
    test "required options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Not all the required options are given for the clone clone. " <>
                     "You forgot specifying [:to]",
                   fn ->
                     defmodule CloneWithoutRequiredOpts do
                       use ALF.DSL

                       @components [clone(:clone, a: :b)]
                     end
                   end
    end

    test "invalid options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Wrong options for the clone clone: [:foo]. " <>
                     "Available options are [:to]",
                   fn ->
                     defmodule CloneWithWrongRequiredOpts do
                       use ALF.DSL

                       @components [clone(:clone, to: :b, foo: :bar)]
                     end
                   end
    end
  end

  describe "Goto" do
    test "required options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Not all the required options are given for the goto goto. " <>
                     "You forgot specifying [:to]",
                   fn ->
                     defmodule GotoWithoutRequiredOpts do
                       use ALF.DSL

                       @components [goto(:goto)]
                     end
                   end
    end

    test "invalid options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Wrong options for the goto goto: [:foo]. " <>
                     "Available options are [:to, :opts, :name]",
                   fn ->
                     defmodule GotoWithWrongRequiredOpts do
                       use ALF.DSL

                       @components [goto(:goto, to: :b, foo: :bar)]
                     end
                   end
    end
  end

  describe "stages_from" do
    defmodule PipelineToReuse do
      use ALF.DSL

      @components [stage(:stage)]
    end

    test "no such module", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "There is no such module: NoSuchModule",
                   fn ->
                     defmodule StageFromWithNonExistingModule do
                       use ALF.DSL

                       @components stages_from(NoSuchModule)
                     end
                   end
    end

    test "invalid options", %{sup_pid: sup_pid} do
      assert_raise DSLError,
                   "Wrong options are given for the stages_from macro: [:foo]. " <>
                     "Available options are [:count, :opts]",
                   fn ->
                     defmodule GotoWithWrongRequiredOpts do
                       use ALF.DSL

                       @components stages_from(PipelineToReuse, foo: :bar)
                     end
                   end
    end
  end

  describe "plug_with" do
    defmodule MyAdapterModule do
      def init(opts), do: opts
      def plug(event, _opts), do: event
      def unplug(_datum, prev_event, _opts), do: prev_event
    end

    test "no such module" do
      assert_raise DSLError,
                   "There is no such module: NoSuchModule",
                   fn ->
                     defmodule PlugWithNonExistingModule do
                       use ALF.DSL

                       @components (plug_with(NoSuchModule) do
                                      [stage(StageA1, name: :custom_name)]
                                    end)
                     end
                   end
    end

    test "invalid options" do
      assert_raise DSLError,
                   "Wrong options are given for the plug_with macro: [:foo]. " <>
                     "Available options are [:module, :name, :opts]",
                   fn ->
                     defmodule PlugWithNonExistingModule do
                       use ALF.DSL

                       @components (plug_with(MyAdapterModule, foo: :bar) do
                                      stages_from(PipelineToReuse, foo: :bar)
                                    end)
                     end
                   end
    end
  end
end
