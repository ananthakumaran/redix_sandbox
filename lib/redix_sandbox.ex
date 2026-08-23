defmodule RedixSandbox do
  @moduledoc """
  Process-scoped Redis connections for concurrent tests.

  Start a named sandbox with `start_link/1`, then check out that sandbox in each
  test with `checkout/1`. Redis commands use the `:via` tuple from `via/1` to
  resolve to the calling test's connection.
  """

  use Supervisor

  alias RedixSandbox.{Errors.AllowError, Errors.CheckoutError, Errors.ModeError, Names}

  @type name :: atom()
  @type mode :: :private | {:shared, pid()}

  @doc """
  Starts a named sandbox.

  Each sandbox owns its Redix connections and `NimbleOwnership` server.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    name = Keyword.fetch!(options, :name)
    Supervisor.start_link(__MODULE__, options, name: Names.supervisor(name))
  end

  @impl true
  @spec init(keyword()) :: term()
  def init(options) do
    name = Keyword.fetch!(options, :name)
    connection = Keyword.fetch!(options, :connection)
    databases = Keyword.fetch!(options, :databases)
    ownership = Names.ownership(name)
    connection_supervisor = Names.connection_supervisor(name)

    connections =
      Enum.map(databases, fn database ->
        %{name: Names.connection(name, database), database: database}
      end)

    children = [
      {NimbleOwnership, name: ownership},
      {RedixSandbox.ConnectionSupervisor, name: connection_supervisor},
      {RedixSandbox.Pool,
       name: Names.pool(name),
       sandbox: name,
       ownership: ownership,
       connection_supervisor: connection_supervisor,
       connection: connection,
       connections: connections}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Checks out a Redis connection for the calling process.

  The pool implementation will reserve a logical Redis DB, flush it, and record
  the calling process as its owner before returning `:ok`. Failures return a
  `RedixSandbox.Errors.CheckoutError` with the sandbox, database when applicable, operation, and
  original reason.
  """
  @spec checkout(name()) :: :ok | {:error, CheckoutError.t()}
  def checkout(name) when is_atom(name) do
    case RedixSandbox.Pool.checkout(Names.pool(name), self()) do
      :ok ->
        :ok

      {:error, {:connection_start_failed, database, reason}} ->
        {:error, checkout_error(name, database, :connection_start, reason)}

      {:error, {:flush_failed, database, reason}} ->
        {:error, checkout_error(name, database, :flush, reason)}

      {:error, reason} ->
        {:error, checkout_error(name, nil, :checkout, reason)}
    end
  end

  @doc """
  Changes the ownership mode of a sandbox.

  In shared mode, the owner must already have checked out the sandbox and all callers
  resolve that owner's Redis connection. Use `:private` to restore process isolation.
  """
  @spec mode(name(), mode()) :: :ok | {:error, ModeError.t()}
  def mode(name, :private) when is_atom(name) do
    mode_result(name, :private, RedixSandbox.Pool.mode(Names.pool(name), :private))
  end

  def mode(name, {:shared, owner}) when is_atom(name) and is_pid(owner) do
    mode_result(
      name,
      {:shared, owner},
      RedixSandbox.Pool.mode(Names.pool(name), {:shared, owner})
    )
  end

  @doc """
  Allows a process to use the calling owner's checked-out Redis connection.

  The owner must already have checked out the sandbox. The child shares the owner's
  logical Redis database.
  """
  @spec allow(name(), pid(), pid()) :: :ok | {:error, AllowError.t()}
  def allow(name, owner, child) when is_atom(name) and is_pid(owner) and is_pid(child) do
    case NimbleOwnership.allow(Names.ownership(name), owner, child, name) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, allow_error(name, owner, child, reason)}
    end
  end

  @doc """
  Returns an OTP `:via` tuple that resolves to the calling process's connection.

  Pass this where a `Redix` connection name is accepted, for example:

      Redix.command(RedixSandbox.via(:redix), ["PING"])
  """
  @spec via(name()) :: {:via, RedixSandbox.Via, {atom(), name()}}
  def via(name) when is_atom(name) do
    {:via, RedixSandbox.Via, {Names.pool(name), name}}
  end

  @spec mode_result(name(), mode(), :ok | {:error, term()}) :: :ok | {:error, ModeError.t()}
  defp mode_result(_sandbox, _mode, :ok), do: :ok

  defp mode_result(sandbox, mode, {:error, reason}),
    do: {:error, mode_error(sandbox, mode, reason)}

  @spec mode_error(name(), mode(), term()) :: ModeError.t()
  defp mode_error(sandbox, mode, reason) do
    %ModeError{
      sandbox: sandbox,
      mode: mode,
      reason: reason,
      message:
        "could not set Redis sandbox #{inspect(sandbox)} to mode #{inspect(mode)}: #{inspect(reason)}"
    }
  end

  @spec allow_error(name(), pid(), pid(), term()) :: AllowError.t()
  defp allow_error(sandbox, owner, child, reason) do
    %AllowError{
      sandbox: sandbox,
      owner: owner,
      child: child,
      reason: reason,
      message:
        "could not allow #{inspect(child)} to use Redis sandbox #{inspect(sandbox)} " <>
          "through #{inspect(owner)}: #{inspect(reason)}"
    }
  end

  @spec checkout_error(
          name(),
          non_neg_integer() | nil,
          :checkout | :connection_start | :flush,
          term()
        ) :: CheckoutError.t()
  defp checkout_error(sandbox, database, operation, reason) do
    %CheckoutError{
      sandbox: sandbox,
      database: database,
      operation: operation,
      reason: reason,
      message:
        "could not checkout Redis sandbox #{inspect(sandbox)}: " <>
          "#{checkout_operation(operation)} failed#{checkout_database(database)}: " <>
          checkout_reason(reason)
    }
  end

  @spec checkout_operation(:checkout | :connection_start | :flush) :: String.t()
  defp checkout_operation(:checkout), do: "checking out a Redis connection"
  defp checkout_operation(:connection_start), do: "starting the Redis connection"
  defp checkout_operation(:flush), do: "FLUSHDB"

  @spec checkout_database(non_neg_integer() | nil) :: String.t()
  defp checkout_database(nil), do: ""
  defp checkout_database(database), do: " for database #{database}"

  @spec checkout_reason(term()) :: String.t()
  defp checkout_reason(:already_checked_out), do: "the calling process already has a connection"
  defp checkout_reason(:pool_exhausted), do: "no logical Redis database is available"
  defp checkout_reason(:shared_mode), do: "the sandbox is in shared mode"

  defp checkout_reason(:multiple_checkouts),
    do: "shared mode requires exactly one checked-out connection"

  defp checkout_reason(%{__exception__: true} = reason), do: Exception.message(reason)
  defp checkout_reason(reason), do: inspect(reason)
end
