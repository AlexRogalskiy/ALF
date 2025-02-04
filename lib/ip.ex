defmodule ALF.IP do
  @moduledoc "Defines internal pipeline struct"

  @type t :: %__MODULE__{
          type: :ip,
          event: any(),
          init_event: any(),
          destination: pid(),
          ref: reference(),
          stream_ref: reference() | nil,
          manager_name: atom(),
          history: list(),
          done!: boolean(),
          decomposed: boolean(),
          recomposed: boolean(),
          plugs: map(),
          sync_path: nil | list()
        }

  defstruct type: :ip,
            event: nil,
            init_event: nil,
            destination: nil,
            ref: nil,
            stream_ref: nil,
            manager_name: nil,
            history: [],
            done!: false,
            decomposed: false,
            recomposed: false,
            plugs: %{},
            sync_path: nil
end
