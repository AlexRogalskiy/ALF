defmodule ALF.Components.GotoTest do
  use ExUnit.Case, async: true
  alias ALF.{IP, TestProducer, TestConsumer}
  alias ALF.Components.{GotoPoint, Stage, Goto}

  setup do
    {:ok, producer_pid} = TestProducer.start_link([])
    %{producer_pid: producer_pid}
  end

  def build_goto_point(producer_pid) do
    %GotoPoint{
      name: :goto_point,
      subscribe_to: [{producer_pid, max_demand: 1}]
    }
  end

  def if_function(event, opts) do
    event < opts[:max]
  end

  def build_goto(stage_pid, goto_point_pid, function) do
    %Goto{
      name: :goto,
      module: __MODULE__,
      function: function,
      pipeline_module: __MODULE__,
      opts: %{max: 2},
      to_pid: goto_point_pid,
      subscribe_to: [{stage_pid, max_demand: 1}]
    }
  end

  def stage_function(event, _) do
    event + 1
  end

  def build_stage(goto_point_pid) do
    %Stage{
      name: :test_stage,
      module: __MODULE__,
      function: :stage_function,
      subscribe_to: [{goto_point_pid, max_demand: 1}]
    }
  end

  def setup_pipeline(producer_pid, if_function) do
    {:ok, goto_point_pid} = GotoPoint.start_link(build_goto_point(producer_pid))
    {:ok, stage_pid} = Stage.start_link(build_stage(goto_point_pid))
    {:ok, goto_pid} = Goto.start_link(build_goto(stage_pid, goto_point_pid, if_function))

    {:ok, consumer_pid} =
      TestConsumer.start_link(%TestConsumer{subscribe_to: [{goto_pid, max_demand: 1}]})

    {consumer_pid, goto_pid}
  end

  def do_run_test(producer_pid, consumer_pid) do
    ip = %IP{event: 0}
    GenServer.cast(producer_pid, [ip])
    Process.sleep(10)
    [ip] = TestConsumer.ips(consumer_pid)
    assert ip.event == 2

    assert ip.history == [
             {:goto, 2},
             {{:test_stage, 0}, 1},
             {:goto_point, 1},
             {:goto, 1},
             {{:test_stage, 0}, 0},
             {:goto_point, 0}
           ]
  end

  describe "with function as atom" do
    setup %{producer_pid: producer_pid} do
      {consumer_pid, goto_pid} = setup_pipeline(producer_pid, :if_function)

      %{consumer_pid: consumer_pid, goto_pid: goto_pid}
    end

    test "test goto", %{producer_pid: producer_pid, consumer_pid: consumer_pid} do
      do_run_test(producer_pid, consumer_pid)
    end

    test "set source_code", %{goto_pid: goto_pid} do
      %{source_code: source_code} = Goto.__state__(goto_pid)
      assert source_code == "def if_function(event, opts) do\n  event < opts[:max]\nend"
    end
  end
end
