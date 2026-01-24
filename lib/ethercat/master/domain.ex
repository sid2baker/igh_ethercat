defmodule EtherCAT.Master.Domain do
  @moduledoc """
    Domain module for EtherCAT master.
  """

  @type t :: %__MODULE__{
          ref: reference(),
          update_rate_us: non_neg_integer()
        }

  defstruct [
    :ref,
    :update_rate_us
  ]
end
