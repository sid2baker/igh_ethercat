defmodule EtherCAT.Master.Slave do
  @moduledoc """
    Slave module for EtherCAT master.
  """

  @type t :: %__MODULE__{
          name: atom(),
          ref: reference(),
          pdo_entries: %{pdo_entry_index() => pdo_entry()},
          configured?: bool()
        }

  @type pdo_entry_index() :: non_neg_integer()

  @type pdo_entry() :: {slave_name(), pdo_name(), entry_name()}

  @type slave_name() :: atom()
  @type pdo_name() :: atom()
  @type entry_name() :: atom()

  defstruct [
    :name,
    :ref,
    :pdo_entries,
    :configured?
  ]
end
