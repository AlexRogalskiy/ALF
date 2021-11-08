defmodule ALF.Consumer do
  use GenStage

  defstruct [
    name: :consumer,
    pid: nil,
    pipe_module: nil,
    subscribe_to: [],
    pipeline_module: nil,
  ]

  def start_link(%__MODULE__{} = state) do
    GenStage.start_link(__MODULE__, state)
  end

  def init(state) do
    {:consumer, %{state | pid: self()}, subscribe_to: state.subscribe_to}
  end

  def handle_events([ip], _from, state) do
    ALF.PipelineManager.result_ready(ip.manager_name, ip)

    {:noreply, [], state}
  end

end
