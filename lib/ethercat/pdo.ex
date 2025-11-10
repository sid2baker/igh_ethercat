defmodule EtherCAT.PDO do
  @moduledoc """
  PDO handle for read/write operations and subscriptions.
  """

  defstruct [:domain, :unique_name, :master]

  @type t :: %__MODULE__{
          domain: atom(),
          unique_name: String.t(),
          master: pid()
        }

  @doc "Creates new PDO handle."
  @spec new(atom(), String.t(), pid()) :: t()
  def new(domain, unique_name, master) do
    %__MODULE__{
      domain: domain,
      unique_name: unique_name,
      master: master
    }
  end
end
