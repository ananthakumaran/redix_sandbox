defmodule RedixSandbox do
  @moduledoc """
  Process-scoped Redis connections for concurrent tests.

  Start a named sandbox with `start_link/1`, then check out that sandbox in each
  test with `checkout/1`. Redis commands use the `:via` tuple from `via/1` to
  resolve to the calling test's connection.
  """

  use Supervisor

  alias RedixSandbox.{CheckoutError, Names}

  @type name :: atom()

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
  `RedixSandbox.CheckoutError` with the sandbox, database when applicable, operation, and
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
  Returns an OTP `:via` tuple that resolves to the calling process's connection.

  Pass this where a `Redix` connection name is accepted, for example:

      Redix.command(RedixSandbox.via(:redix), ["PING"])
  """
  @spec via(name()) :: {:via, RedixSandbox.Via, {atom(), name()}}
  def via(name) when is_atom(name) do
    {:via, RedixSandbox.Via, {Names.pool(name), name}}
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
  defp checkout_reason(%{__exception__: true} = reason), do: Exception.message(reason)
  defp checkout_reason(reason), do: inspect(reason)
end
