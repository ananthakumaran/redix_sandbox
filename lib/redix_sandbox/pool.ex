defmodule RedixSandbox.Pool do
  @moduledoc """
  Owns sandbox leases and lazily started Redis connections.
  """

  use GenServer

  @type database :: non_neg_integer()
  @type sandbox :: RedixSandbox.name()
  @type connection :: %{name: atom(), database: database()}
  @type ownership :: atom()
  @type connection_supervisor :: atom()
  @type lease :: %{connection: connection(), monitor: reference()}
  @type state :: %__MODULE__{
          sandbox: sandbox(),
          ownership: ownership(),
          connection_supervisor: connection_supervisor(),
          connection_options: keyword(),
          available: [connection()],
          leases: %{pid() => lease()},
          monitors: %{reference() => pid()}
        }

  defstruct sandbox: nil,
            ownership: nil,
            connection_supervisor: nil,
            connection_options: [],
            available: [],
            leases: %{},
            monitors: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
    {genserver_options, pool_options} = Keyword.split(options, [:name])
    GenServer.start_link(__MODULE__, pool_options, genserver_options)
  end

  @spec checkout(GenServer.server(), pid()) :: :ok | {:error, term()}
  def checkout(pool, owner) when is_pid(owner) do
    GenServer.call(pool, {:checkout, owner})
  end

  @type connection_result ::
          {:ok, pid()} | {:error, :not_checked_out | :connection_unavailable}

  @spec connection_for(GenServer.server(), [pid()]) :: connection_result()
  def connection_for(pool, callers) when is_list(callers) do
    GenServer.call(pool, {:connection_for, callers})
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(options) do
    {:ok,
     %__MODULE__{
       sandbox: Keyword.fetch!(options, :sandbox),
       ownership: Keyword.fetch!(options, :ownership),
       connection_supervisor: Keyword.fetch!(options, :connection_supervisor),
       connection_options: Keyword.fetch!(options, :connection),
       available: Keyword.fetch!(options, :connections)
     }}
  end

  @impl true
  @spec handle_call({:checkout, pid()} | {:connection_for, [pid()]}, GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()} | connection_result(), state()}
  def handle_call({:connection_for, callers}, _from, state) do
    connection =
      case NimbleOwnership.fetch_owner(state.ownership, callers, state.sandbox) do
        {tag, owner} when tag in [:ok, :shared_owner] ->
          case NimbleOwnership.get_owned(state.ownership, owner, %{})[state.sandbox] do
            %{name: name} ->
              case Process.whereis(name) do
                pid when is_pid(pid) -> {:ok, pid}
                nil -> {:error, :connection_unavailable}
              end

            _ ->
              {:error, :not_checked_out}
          end

        :error ->
          {:error, :not_checked_out}
      end

    {:reply, connection, state}
  end

  def handle_call({:checkout, owner}, _from, %{leases: leases} = state)
      when is_map_key(leases, owner) do
    {:reply, {:error, :already_checked_out}, state}
  end

  def handle_call({:checkout, _owner}, _from, %{available: []} = state) do
    {:reply, {:error, :pool_exhausted}, state}
  end

  def handle_call({:checkout, owner}, _from, %{available: [connection | _]} = state) do
    case checkout_connection(owner, connection, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  @spec handle_info({:DOWN, reference(), :process, pid(), term()}, state()) ::
          {:noreply, state()}
  def handle_info({:DOWN, reference, :process, owner, _reason}, state) do
    case Map.pop(state.monitors, reference) do
      {^owner, monitors} ->
        {lease, leases} = Map.pop(state.leases, owner)

        state = %{
          state
          | monitors: monitors,
            leases: leases,
            available: [lease.connection | state.available]
        }

        {:noreply, state}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  @spec checkout_connection(pid(), connection(), state()) :: {:ok, state()} | {:error, term()}
  defp checkout_connection(owner, connection, state) do
    with :ok <- ensure_connection(connection, state),
         :ok <- flush_connection(connection),
         :ok <- register_owner(owner, connection, state) do
      monitor = Process.monitor(owner)
      lease = %{connection: connection, monitor: monitor}

      {:ok,
       %{
         state
         | available: List.delete(state.available, connection),
           leases: Map.put(state.leases, owner, lease),
           monitors: Map.put(state.monitors, monitor, owner)
       }}
    end
  end

  @spec ensure_connection(connection(), state()) :: :ok | {:error, term()}
  defp ensure_connection(connection, state) do
    case Process.whereis(connection.name) do
      nil ->
        options =
          state.connection_options
          |> Keyword.put(:name, connection.name)
          |> Keyword.put(:database, connection.database)

        case DynamicSupervisor.start_child(state.connection_supervisor, {Redix, options}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:connection_start_failed, connection.database, reason}}
        end

      _pid ->
        :ok
    end
  end

  @spec flush_connection(connection()) :: :ok | {:error, term()}
  defp flush_connection(connection) do
    case Redix.command(connection.name, ["FLUSHDB"]) do
      {:ok, "OK"} -> :ok
      {:ok, response} -> {:error, {:unexpected_flush_response, response}}
      {:error, reason} -> {:error, {:flush_failed, connection.database, reason}}
    end
  end

  @spec register_owner(pid(), connection(), state()) :: :ok | {:error, term()}
  defp register_owner(owner, connection, state) do
    case NimbleOwnership.get_and_update(state.ownership, owner, state.sandbox, fn _metadata ->
           {:ok, connection}
         end) do
      {:ok, _value} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
