defmodule ALF.SyncRun.BubbleSortWithSwitch.Pipeline do
  use ALF.DSL

  defstruct [:list, :new_list, :max, :ready]

  @components [
    stage(:build_struct),
    goto_point(:goto_point),
    stage(:find_max),
    stage(:update_new_list, count: 10),
    stage(:rebuild_list, count: 10),
    clone(:logging, to: [stage(:report_step), dead_end(:after_report)]),
    switch(:ready_or_not,
      branches: %{
        ready: [stage(:format_output)],
        not_ready: [goto(true, to: :goto_point, name: :just_go)]
      }
    )
  ]

  def build_struct(list, _) do
    %__MODULE__{list: list, new_list: [], max: 0, ready: false}
  end

  def find_max(struct, _) do
    %{struct | max: Enum.max(struct.list)}
  end

  def update_new_list(struct, _) do
    %{struct | new_list: [struct.max | struct.new_list]}
  end

  def rebuild_list(struct, _) do
    %{struct | list: struct.list -- [struct.max]}
  end

  def report_step(struct, _) do
    #    IO.inspect("Step: #{inspect struct}", charlists: :as_lists)
    struct
  end

  def format_output(struct, _) do
    struct.new_list
  end

  def ready_or_not(struct, _) do
    if Enum.empty?(struct.list) do
      :ready
    else
      :not_ready
    end
  end
end

defmodule ALF.SyncRun.BubbleSortWithSwitchTest do
  use ExUnit.Case, async: true

  alias ALF.SyncRun.BubbleSortWithSwitch.Pipeline

  @range 1..5

  setup do
    Pipeline.start(sync: true)
    on_exit(&Pipeline.stop/0)
  end

  test "sort" do
    [result] =
      [Enum.shuffle(@range)]
      |> Pipeline.stream()
      |> Enum.to_list()

    assert result == Enum.to_list(@range)
  end
end
