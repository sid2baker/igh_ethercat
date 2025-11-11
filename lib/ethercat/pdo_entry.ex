defmodule EtherCAT.PDOEntry do
  @moduledoc """
  Handle for a registered PDO entry, used for read/write operations and subscriptions.

  Each PDOEntry represents a single registered entry within a PDO, providing direct access
  to the domain process for efficient operations without Registry lookups.
  """

  defstruct [:domain_pid, :unique_name]

  @type t :: %__MODULE__{
          domain_pid: pid(),
          unique_name: String.t()
        }

  @doc "Creates new PDO entry handle."
  @spec new(pid(), String.t()) :: t()
  def new(domain_pid, unique_name) do
    %__MODULE__{
      domain_pid: domain_pid,
      unique_name: unique_name
    }
  end
end
