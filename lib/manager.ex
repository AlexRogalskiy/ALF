defmodule ALF.Manager do
  use GenServer

  # TODO revise the list
  defstruct name: nil,
            pipeline_module: nil,
            pid: nil,
            pipeline: nil,
            components: [],
            stages_to_be_deleted: [],
            pipeline_sup_pid: nil,
            sup_pid: nil,
            producer_pid: nil,
            registry: %{},
            registry_dump: %{},
            telemetry_enabled: nil,
            sync: false

  alias ALF.Components.{Goto, Producer}
  alias ALF.{Builder, Introspection, PipelineDynamicSupervisor, Pipeline, SyncRunner}
  alias ALF.{ErrorIP, IP}

  @type t :: %__MODULE__{}

  @available_options [:telemetry_enabled, :sync]
  @default_timeout 60_000

  def start_link(%__MODULE__{} = state) do
    GenServer.start_link(__MODULE__, state, name: state.name)
  end

  def init(%__MODULE__{} = state) do
    state = %{state | pid: self()}

    if state.sync do
      pipeline = Builder.build_sync(state.pipeline_module, state.telemetry_enabled)
      {:ok, %{state | pipeline: pipeline, components: Pipeline.stages_to_list(pipeline)}}
    else
      {:ok, start_pipeline(state)}
    end
  end

  @spec start(atom) :: :ok
  def start(module) when is_atom(module) do
    start(module, module, [])
  end

  # TODO no names anymore
  @spec start(atom, atom) :: :ok
  def start(module, name) when is_atom(module) and is_atom(name) do
    start(module, name, [])
  end

  @spec start(atom, list) :: :ok
  def start(module, opts) when is_atom(module) and is_list(opts) do
    start(module, module, opts)
  end

  @spec start(atom, atom, list) :: :ok
  def start(module, name, opts) when is_atom(module) and is_atom(name) and is_list(opts) do
    unless is_pipeline_module?(module) do
      raise "The #{module} doesn't implement any pipeline"
    end

    wrong_options = Keyword.keys(opts) -- @available_options

    if Enum.any?(wrong_options) do
      raise "Wrong options for the '#{name}' pipeline: #{inspect(wrong_options)}. " <>
              "Available options are #{inspect(@available_options)}"
    end

    sup_pid = Process.whereis(ALF.DynamicSupervisor)

    name = if name, do: name, else: module

    case DynamicSupervisor.start_child(
           sup_pid,
           %{
             id: __MODULE__,
             start:
               {__MODULE__, :start_link,
                [
                  %__MODULE__{
                    sup_pid: sup_pid,
                    name: name,
                    pipeline_module: module,
                    telemetry_enabled:
                      Keyword.get(opts, :telemetry_enabled, nil) ||
                        telemetry_enabled_in_configs?(),
                    sync: Keyword.get(opts, :sync, false)
                  }
                ]},
             restart: :transient
           }
         ) do
      {:ok, _manager_pid} ->
        Introspection.add(module)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  def stop(module) when is_atom(module) do
    result = GenServer.call(module, :stop, :infinity)
    Introspection.remove(module)
    result
  catch
    :exit, {reason, details} ->
      {:exit, {reason, details}}
  end

  # TODO remove later
  @spec stream_to(Enumerable.t(), atom(), map() | keyword()) :: Enumerable.t()
  def stream_to(stream, name, opts \\ []) when is_atom(name) do
    stream(stream, name, opts)
  end

  @spec components(atom) :: list(map())
  def components(name) when is_atom(name) do
    GenServer.call(name, :components)
  end

  @spec reload_components_states(atom()) :: list(map())
  def reload_components_states(name) when is_atom(name) do
    GenServer.call(name, :reload_components_states)
  end

  def terminate(:normal, state) do
    unless state.sync do
      Supervisor.stop(state.pipeline_sup_pid)
    end
  end

  def __state__(name_or_pid) when is_atom(name_or_pid) or is_pid(name_or_pid) do
    GenServer.call(name_or_pid, :__state__)
  end

  def __set_state__(name_or_pid, new_state) when is_atom(name_or_pid) or is_pid(name_or_pid) do
    GenServer.call(name_or_pid, {:__set_state__, new_state})
  end

  defp start_pipeline(%__MODULE__{} = state) do
    state
    |> start_pipeline_supervisor()
    |> build_pipeline()
    |> save_stages_states()
    |> prepare_gotos()
  end

  defp start_pipeline_supervisor(%__MODULE__{} = state) do
    pipeline_sup_pid =
      case PipelineDynamicSupervisor.start_link(%{name: :"#{state.name}_DynamicSupervisor"}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.unlink(pipeline_sup_pid)
    Process.monitor(pipeline_sup_pid)
    %{state | pipeline_sup_pid: pipeline_sup_pid}
  end

  defp build_pipeline(%__MODULE__{} = state) do
    {:ok, pipeline} =
      Builder.build(
        state.pipeline_module,
        state.pipeline_sup_pid,
        state.name,
        state.telemetry_enabled
      )

    %{state | pipeline: pipeline, producer_pid: pipeline.producer.pid}
  end

  defp save_stages_states(%__MODULE__{} = state) do
    components =
      [state.pipeline.producer | Pipeline.stages_to_list(state.pipeline.components)] ++
        [state.pipeline.consumer]

    components =
      components
      |> Enum.map(fn stage ->
        stage.__struct__.__state__(stage.pid)
      end)

    %{state | components: components}
  end

  defp prepare_gotos(%__MODULE__{} = state) do
    components =
      state.components
      |> Enum.map(fn component ->
        case component do
          %Goto{} ->
            Goto.find_where_to_go(component.pid, state.components)

          stage ->
            stage
        end
      end)

    %{state | components: components}
  end

  def handle_call(:__state__, _from, state), do: {:reply, state, state}

  def handle_call({:__set_state__, new_state}, _from, _state) do
    {:reply, new_state, new_state}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, state, state}
  end

  def handle_call(:components, _from, state) do
    {:reply, state.components, state}
  end

  def handle_call(:reload_components_states, _from, %__MODULE__{sync: false} = state) do
    components =
      state.components
      |> Enum.map(fn stage ->
        stage.__struct__.__state__(stage.pid)
      end)

    {:reply, components, %{state | components: components}}
  end

  def handle_call(:reload_components_states, _from, %__MODULE__{sync: true} = state) do
    {:reply, state.components, state}
  end

  def handle_call(:sync_pipeline, _from, state) do
    if state.sync do
      {:reply, state.pipeline, state}
    else
      raise "#{state.name} is not a sync pipeline"
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, :shutdown}, %__MODULE__{} = state) do
    state = start_pipeline(state)

    {:noreply, state}
  end

  defp is_pipeline_module?(module) when is_atom(module) do
    is_list(module.alf_components())
  rescue
    _error -> false
  end

  defp telemetry_enabled_in_configs? do
    Application.get_env(:alf, :telemetry_enabled, false)
  end

  def call(event, name, opts \\ [return_ip: false]) do
    case status(name) do
      {:ok, producer_name} ->
        do_call(name, producer_name, event, opts)

      {:sync, pipeline} ->
        do_sync_call(name, pipeline, event, opts)
    end
  end

  defp do_call(name, producer_name, event, opts) do
    ip = build_ip(event, name)
    Producer.load_ip(producer_name, ip)
    timeout = opts[:timeout] || @default_timeout

    case wait_result(ip.ref, [], {timeout, ip}) do
      [] ->
        nil

      [ip] ->
        format_ip(ip, opts[:return_ip])

      ips ->
        Enum.map(ips, fn ip -> format_ip(ip, opts[:return_ip]) end)
    end
  end

  defp do_sync_call(name, pipeline, event, opts) do
    ip = build_ip(event, name)
    [ip] = SyncRunner.run(pipeline, ip)
    format_ip(ip, opts[:return_ip])
  end

  def handle_cast({:load_ip, ip}, state) do
    Producer.load_ip(state.producer_pid, ip)

    {:noreply, state}
  end

  def stream(stream, name, opts \\ [return_ips: false]) do
    case status(name) do
      {:ok, producer_name} ->
        do_stream(name, producer_name, stream, opts)

      {:sync, pipeline} ->
        do_sync_stream(name, pipeline, stream, opts)
    end
  end

  defp do_stream(name, producer_name, stream, opts) do
    new_stream_ref = make_ref()
    timeout = opts[:timeout] || @default_timeout

    stream
    |> Stream.transform(
      nil,
      fn event, nil ->
        ip = build_ip(event, name)
        ip = %{ip | new_stream_ref: new_stream_ref}
        Producer.load_ip(producer_name, ip)

        case wait_result(new_stream_ref, [], {timeout, ip}) do
          [] ->
            {[], nil}

          ips ->
            ips = Enum.map(ips, fn ip -> format_ip(ip, opts[:return_ips]) end)
            {ips, nil}
        end
      end
    )
  end

  defp do_sync_stream(name, pipeline, stream, opts) do
    stream
    |> Stream.transform(
      nil,
      fn event, nil ->
        ip = build_ip(event, name)
        ips = SyncRunner.run(pipeline, ip)
        ips = Enum.map(ips, fn ip -> format_ip(ip, opts[:return_ips]) end)
        {ips, nil}
      end
    )
  end

  defp wait_result(ref, acc, {timeout, initial_ip}) do
    receive do
      {^ref, :created_recomposer} ->
        wait_result(ref, acc, {timeout, initial_ip})

      {^ref, reason} when reason in [:created_decomposer, :cloned] ->
        wait_result(
          ref,
          acc ++ wait_result(ref, [], {timeout, initial_ip}),
          {timeout, initial_ip}
        )

      {^ref, :destroyed} ->
        acc

      {^ref, ip} ->
        Enum.reverse([ip | acc])
    after
      timeout ->
        error_ip = ALF.Components.Basic.build_error_ip(initial_ip, :timeout, [], :no_info)
        Enum.reverse([error_ip | acc])
    end
  end

  defp status(name) do
    producer_name = :"#{name}.Producer"

    cond do
      Process.whereis(producer_name) && Process.whereis(name) ->
        {:ok, producer_name}

      is_nil(Process.whereis(producer_name)) && Process.whereis(name) ->
        {:sync, GenServer.call(name, :sync_pipeline)}

      true ->
        raise("Pipeline #{name} is not started")
    end
  end

  defp format_ip(%IP{} = ip, true), do: ip
  defp format_ip(%IP{} = ip, false), do: ip.event
  defp format_ip(%IP{} = ip, nil), do: ip.event
  defp format_ip(%ErrorIP{} = ip, _return_ips), do: ip

  defp build_ip(event, name) do
    %IP{
      ref: make_ref(),
      destination: self(),
      init_datum: event,
      event: event,
      manager_name: name
    }
  end
end
