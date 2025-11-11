defmodule EtherCAT.PDOEntry do
  @moduledoc """
  Handle for a registered PDO entry, used for read/write operations and subscriptions.

  Each PDOEntry represents a single registered entry within a PDO, providing direct access
  to the slave process which routes to the appropriate domain and handles type conversion.
  """

  defstruct [:slave_pid, :pdo_name, :entry_name]

  @type t :: %__MODULE__{
          slave_pid: pid(),
          pdo_name: atom(),
          entry_name: atom()
        }

  @doc "Creates new PDO entry handle."
  @spec new(pid(), atom(), atom()) :: t()
  def new(slave_pid, pdo_name, entry_name) do
    %__MODULE__{
      slave_pid: slave_pid,
      pdo_name: pdo_name,
      entry_name: entry_name
    }
  end
end
