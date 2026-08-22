defmodule RedixSandbox.Via do
  @moduledoc false

  alias RedixSandbox.Errors.{ConnectionUnavailableError, NotCheckedOutError}
  alias RedixSandbox.Pool

  @type name :: {GenServer.server(), RedixSandbox.name()}

  @spec whereis_name(name()) :: pid()
  def whereis_name({pool, sandbox}) do
    callers = caller_pids()

    case Pool.connection_for(pool, callers) do
      {:ok, connection} ->
        connection

      {:error, :not_checked_out} ->
        raise NotCheckedOutError,
          sandbox: sandbox,
          callers: callers,
          message:
            "no checked-out Redis connection for sandbox #{inspect(sandbox)} in process " <>
              "#{inspect(self())} or its callers #{inspect(callers)}. " <>
              "Call RedixSandbox.checkout(#{inspect(sandbox)}) before using RedixSandbox.via/1"

      {:error, :connection_unavailable} ->
        raise ConnectionUnavailableError,
          sandbox: sandbox,
          message:
            "the Redis connection for checked-out sandbox #{inspect(sandbox)} is unavailable. " <>
              "Retry the command after the connection restarts"
    end
  end

  @spec register_name(name(), pid()) :: :no
  def register_name(_name, _pid), do: :no

  @spec unregister_name(name()) :: :ok
  def unregister_name(_name), do: :ok

  @spec send(name(), term()) :: term()
  def send(name, message) do
    Kernel.send(whereis_name(name), message)
  end

  @spec caller_pids() :: [pid()]
  defp caller_pids do
    case Process.get(:"$callers") do
      nil -> [self() | recursive_parents(self())]
      pids when is_list(pids) -> pids
    end
  end

  @spec recursive_parents(pid() | :undefined) :: [pid()]
  defp recursive_parents(:undefined), do: []

  defp recursive_parents(pid) when is_pid(pid) do
    Process.info(pid, :parent)
  rescue
    ArgumentError ->
      []
  else
    {:parent, parent_pid} ->
      [parent_pid | recursive_parents(parent_pid)]
  end
end
