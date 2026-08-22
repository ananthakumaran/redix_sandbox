defmodule RedixSandbox.Names do
  @moduledoc false

  @type sandbox :: RedixSandbox.name()

  @spec supervisor(sandbox()) :: atom()
  def supervisor(sandbox), do: derived_name(sandbox, "supervisor")

  @spec ownership(sandbox()) :: atom()
  def ownership(sandbox), do: derived_name(sandbox, "ownership")

  @spec connection_supervisor(sandbox()) :: atom()
  def connection_supervisor(sandbox), do: derived_name(sandbox, "connection_supervisor")

  @spec connection(sandbox(), non_neg_integer()) :: atom()
  def connection(sandbox, database), do: derived_name(sandbox, "connection_#{database}")

  @spec pool(sandbox()) :: atom()
  def pool(sandbox), do: derived_name(sandbox, "pool")

  @spec derived_name(sandbox(), String.t()) :: atom()
  defp derived_name(sandbox, suffix) do
    String.to_atom("redix_sandbox_#{sandbox}_#{suffix}")
  end
end
