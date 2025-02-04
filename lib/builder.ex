defmodule ALF.Builder do
  alias ALF.Pipeline

  alias ALF.Components.{
    Producer,
    Stage,
    Goto,
    DeadEnd,
    GotoPoint,
    Switch,
    Clone,
    Consumer,
    Plug,
    Unplug,
    Decomposer,
    Recomposer,
    Tbd
  }

  @spec build(atom, pid, atom, boolean) :: {:ok, Pipeline.t()}
  def build(pipeline_module, supervisor_pid, manager_name, telemetry_enabled) do
    pipe_spec = pipeline_module.alf_components()
    producer = start_producer(supervisor_pid, manager_name, pipeline_module, telemetry_enabled)

    {last_stages, final_stages} =
      do_build_pipeline(pipe_spec, [producer], supervisor_pid, [], telemetry_enabled)

    consumer =
      start_consumer(
        supervisor_pid,
        last_stages,
        manager_name,
        pipeline_module,
        telemetry_enabled
      )

    {producer, consumer} =
      set_modules_to_producer_and_consumer({producer, consumer}, pipeline_module)

    pipeline = %Pipeline{producer: producer, consumer: consumer, components: final_stages}
    {:ok, pipeline}
  end

  defp do_build_pipeline(pipe_spec, producers, supervisor_pid, final_stages, telemetry_enabled)
       when is_list(pipe_spec) do
    pipe_spec
    |> Enum.reduce({producers, final_stages}, fn stage_spec, {prev_stages, stages} ->
      case stage_spec do
        %Stage{count: count} = stage ->
          stage_set_ref = make_ref()

          new_stages =
            Enum.map(0..(count - 1), fn number ->
              start_stage(
                %{stage | stage_set_ref: stage_set_ref, number: number},
                supervisor_pid,
                prev_stages,
                telemetry_enabled
              )
            end)

          {new_stages, stages ++ new_stages}

        %Goto{} = goto ->
          goto = start_stage(goto, supervisor_pid, prev_stages, telemetry_enabled)
          {[goto], stages ++ [goto]}

        %DeadEnd{} = dead_end ->
          dead_end = start_stage(dead_end, supervisor_pid, prev_stages, telemetry_enabled)
          {[], stages ++ [dead_end]}

        %GotoPoint{} = goto_point ->
          goto_point = start_stage(goto_point, supervisor_pid, prev_stages, telemetry_enabled)
          {[goto_point], stages ++ [goto_point]}

        %Switch{branches: branches} = switch ->
          switch = start_stage(switch, supervisor_pid, prev_stages, telemetry_enabled)

          {last_stages, branches} =
            Enum.reduce(branches, {[], %{}}, fn {key, inner_pipe_spec},
                                                {all_last_stages, branches} ->
              {last_stages, final_stages} =
                do_build_pipeline(
                  inner_pipe_spec,
                  [{switch, partition: key}],
                  supervisor_pid,
                  [],
                  telemetry_enabled
                )

              {all_last_stages ++ last_stages, Map.put(branches, key, final_stages)}
            end)

          switch = %{switch | branches: branches}

          {last_stages, stages ++ [switch]}

        %Clone{to: pipe_stages} = clone ->
          clone = start_stage(clone, supervisor_pid, prev_stages, telemetry_enabled)

          {last_stages, final_stages} =
            do_build_pipeline(pipe_stages, [clone], supervisor_pid, [], telemetry_enabled)

          clone = %{clone | to: final_stages}

          {last_stages ++ [clone], stages ++ [clone]}

        %Plug{} = plug ->
          plug = start_stage(plug, supervisor_pid, prev_stages, telemetry_enabled)
          {[plug], stages ++ [plug]}

        %Unplug{} = unplug ->
          unplug = start_stage(unplug, supervisor_pid, prev_stages, telemetry_enabled)
          {[unplug], stages ++ [unplug]}

        %Decomposer{} = decomposer ->
          decomposer = start_stage(decomposer, supervisor_pid, prev_stages, telemetry_enabled)
          {[decomposer], stages ++ [decomposer]}

        %Recomposer{} = recomposer ->
          recomposer = start_stage(recomposer, supervisor_pid, prev_stages, telemetry_enabled)
          {[recomposer], stages ++ [recomposer]}

        %Tbd{} = tbd ->
          tbd = start_stage(tbd, supervisor_pid, prev_stages, telemetry_enabled)
          {[tbd], stages ++ [tbd]}
      end
    end)
  end

  @spec build_sync(atom, boolean) :: [map]
  def build_sync(pipeline_module, telemetry_enabled) do
    pipe_spec = pipeline_module.alf_components()
    producer = Producer.init_sync(%Producer{pipeline_module: pipeline_module}, telemetry_enabled)
    {components, last_stage_refs} = do_build_sync(pipe_spec, [producer.pid], telemetry_enabled)
    consumer = Consumer.init_sync(%Consumer{pipeline_module: pipeline_module}, telemetry_enabled)
    subscribed_to = Enum.map(last_stage_refs, &{&1, :sync})
    consumer = %{consumer | subscribed_to: subscribed_to}
    [producer | components] ++ [consumer]
  end

  defp do_build_sync(pipe_spec, stage_refs, telemetry_enabled) when is_list(pipe_spec) do
    Enum.reduce(pipe_spec, {[], stage_refs}, fn comp, {stages, last_stage_refs} ->
      subscribed_to = Enum.map(last_stage_refs, &{&1, :sync})

      case comp do
        %Switch{branches: branches} = switch ->
          switch = switch.__struct__.init_sync(switch, telemetry_enabled)

          branches =
            Enum.reduce(branches, %{}, fn {key, inner_pipe_spec}, branch_pipes ->
              {branch_stages, _last_ref} =
                do_build_sync(inner_pipe_spec, [switch.pid], telemetry_enabled)

              Map.put(branch_pipes, key, branch_stages)
            end)

          switch = %{switch | branches: branches, subscribed_to: subscribed_to}

          last_stage_refs =
            Enum.map(branches, fn {_key, stages} ->
              case List.last(stages) do
                nil -> nil
                stage -> stage.pid
              end
            end)

          {stages ++ [switch], last_stage_refs}

        %Clone{to: pipe_stages} = clone ->
          clone = clone.__struct__.init_sync(clone, telemetry_enabled)
          {to_stages, _last_ref} = do_build_sync(pipe_stages, [clone.pid], telemetry_enabled)
          clone = %{clone | to: to_stages, subscribed_to: subscribed_to}
          {stages ++ [clone], [clone.pid]}

        component ->
          component = component.__struct__.init_sync(component, telemetry_enabled)
          component = %{component | subscribed_to: subscribed_to}
          {stages ++ [component], [component.pid]}
      end
    end)
  end

  defp start_producer(supervisor_pid, manager_name, pipeline_module, telemetry_enabled) do
    producer = %Producer{
      manager_name: manager_name,
      pipeline_module: pipeline_module,
      telemetry_enabled: telemetry_enabled
    }

    {:ok, producer_pid} = DynamicSupervisor.start_child(supervisor_pid, {Producer, producer})
    %{producer | pid: producer_pid}
  end

  defp start_consumer(
         supervisor_pid,
         last_stages,
         manager_name,
         pipeline_module,
         telemetry_enabled
       ) do
    subscribe_to = subscribe_to_opts(last_stages)

    consumer = %Consumer{
      subscribe_to: subscribe_to,
      manager_name: manager_name,
      pipeline_module: pipeline_module,
      telemetry_enabled: telemetry_enabled
    }

    {:ok, consumer_pid} = DynamicSupervisor.start_child(supervisor_pid, {Consumer, consumer})
    %{consumer | pid: consumer_pid}
  end

  defp set_modules_to_producer_and_consumer({producer, consumer}, pipeline_module) do
    producer = %{producer | pipe_module: pipeline_module, pipeline_module: pipeline_module}
    consumer = %{consumer | pipe_module: pipeline_module, pipeline_module: pipeline_module}

    {producer, consumer}
  end

  defp start_stage(stage, supervisor_pid, prev_stages, telemetry_enabled) do
    stage = %{
      stage
      | subscribe_to: subscribe_to_opts(prev_stages),
        telemetry_enabled: telemetry_enabled
    }

    {:ok, stage_pid} = DynamicSupervisor.start_child(supervisor_pid, {stage.__struct__, stage})
    %{stage | pid: stage_pid}
  end

  defp subscribe_to_opts(stages) do
    Enum.map(stages, fn stage ->
      case stage do
        {stage, partition: key} ->
          {stage.pid, max_demand: 1, cancel: :transient, partition: key}

        stage ->
          {stage.pid, max_demand: 1, cancel: :transient}
      end
    end)
  end
end
