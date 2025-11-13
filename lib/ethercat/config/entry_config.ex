defmodule EtherCAT.Config.EntryConfig do
  @moduledoc """
  Entry routing configuration.

  Maps a specific PDO entry to a domain for cyclic updates.
  """

  defstruct [
    :pdo_name,
    :entry_name,
    :domain
  ]

  @type t :: %__MODULE__{
          pdo_name: atom(),
          entry_name: atom(),
          domain: atom()
        }

  @doc """
  Creates a new entry routing configuration.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., :ch1)
  - `entry_name` - Entry identifier within PDO (e.g., :value)
  - `domain` - Target domain name
  """
  @spec new(atom(), atom(), atom()) :: t()
  def new(pdo_name, entry_name, domain)
      when is_atom(pdo_name) and is_atom(entry_name) and is_atom(domain) do
    %__MODULE__{
      pdo_name: pdo_name,
      entry_name: entry_name,
      domain: domain
    }
  end
end
