defmodule ALF.Components.Stage do
  use ALF.Components.Basic

  defstruct type: :stage,
            name: nil,
            count: 1,
            number: 0,
            stage_set_ref: nil,
            pipe_module: nil,
            pipeline_module: nil,
            module: nil,
            function: nil,
            opts: %{},
            pid: nil,
            source_code: nil,
            subscribe_to: [],
            subscribed_to: [],
            subscribers: [],
            telemetry_enabled: false

  alias ALF.{Manager.Streamer, DoneStatement, DSLError}

  @dsl_options [:opts, :count, :name]

  def start_link(%__MODULE__{} = state) do
    GenStage.start_link(__MODULE__, state)
  end

  def init(state) do
    state = %{
      state
      | pid: self(),
        opts: init_opts(state.module, state.opts),
        source_code: read_source_code(state.module, state.function),
        subscribers: []
    }

    {:producer_consumer, state, subscribe_to: state.subscribe_to}
  end

  def inc_count(state), do: GenStage.call(state.pid, :inc_count)
  def dec_count(state), do: GenStage.call(state.pid, :dec_count)

  def handle_call(:inc_count, _from, state) do
    state = %{state | count: state.count + 1}
    {:reply, state, [], state}
  end

  def handle_call(:dec_count, _from, state) do
    state = %{state | count: state.count - 1}
    {:reply, state, [], state}
  end

  def handle_events([%IP{} = ip], _from, %__MODULE__{telemetry_enabled: true} = state) do
    :telemetry.span(
      [:alf, :component],
      telemetry_data(ip, state),
      fn ->
        case do_handle_event(ip, state) do
          {:noreply, [ip], state} = result ->
            {result, telemetry_data(ip, state)}

          {:noreply, [], state} = result ->
            {result, telemetry_data(nil, state)}
        end
      end
    )
  end

  def handle_events([%IP{} = ip], _from, %__MODULE__{telemetry_enabled: false} = state) do
    do_handle_event(ip, state)
  end

  defp do_handle_event(ip, state) do
    case process_ip(ip, state) do
      %IP{} = ip ->
        {:noreply, [ip], state}

      nil ->
        {:noreply, [], state}
    end
  end

  def validate_options(atom, options) do
    wrong_options = Keyword.keys(options) -- @dsl_options

    unless is_atom(atom) do
      raise DSLError, "Stage must be an atom: #{inspect(atom)}"
    end

    if Enum.any?(wrong_options) do
      raise DSLError,
            "Wrong options for the #{atom} stage: #{inspect(wrong_options)}. " <>
              "Available options are #{inspect(@dsl_options)}"
    end
  end

  defp process_ip(ip, state) do
    ip = %{ip | history: [{{state.name, state.number}, ip.event} | ip.history]}

    case try_apply(ip.event, {state.module, state.function, state.opts}) do
      {:ok, new_datum} ->
        %{ip | event: new_datum}

      {:error, %DoneStatement{event: event}, _stacktrace} ->
        ip = %{ip | event: event}
        Streamer.cast_result_ready(ip.manager_name, ip)
        nil

      {:error, error, stacktrace} ->
        send_error_result(ip, error, stacktrace, state)
        nil
    end
  end

  defp try_apply(event, {module, function, opts}) do
    new_datum = apply(module, function, [event, opts])
    {:ok, new_datum}
  rescue
    error ->
      {:error, error, __STACKTRACE__}
  catch
    kind, value ->
      {:error, kind, value}
  end
end
