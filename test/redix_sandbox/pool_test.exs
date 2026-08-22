defmodule RedixSandbox.PoolTest do
  use ExUnit.Case, async: true

  test "starts named sandboxes without opening Redis connections" do
    {:ok, first_supervisor} =
      RedixSandbox.start_link(
        name: :first_pool_test,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [14]
      )

    {:ok, second_supervisor} =
      RedixSandbox.start_link(
        name: :second_pool_test,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [15]
      )

    assert Process.alive?(first_supervisor)
    assert Process.alive?(second_supervisor)

    first = connection(:first_pool_test)
    second = connection(:second_pool_test)

    assert first.database == 14
    assert second.database == 15
    assert Process.whereis(first.name) == nil
    assert Process.whereis(second.name) == nil
  end

  test "checkout starts and flushes a connection" do
    name = :checkout_pool_test
    key = "redix_sandbox:stale"

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [13]
      )

    connection = connection(name)
    {:ok, seed} = Redix.start_link(host: "127.0.0.1", port: 6379, database: 13)

    try do
      assert {:ok, "OK"} = Redix.command(seed, ["SET", key, "stale value"])
      assert Process.whereis(connection.name) == nil

      assert :ok = RedixSandbox.checkout(name)
      assert is_pid(Process.whereis(connection.name))
      assert {:ok, nil} = Redix.command(connection.name, ["GET", key])

      assert {:error,
              %RedixSandbox.CheckoutError{
                sandbox: ^name,
                database: nil,
                operation: :checkout,
                reason: :already_checked_out,
                message: message
              }} = RedixSandbox.checkout(name)

      assert message =~ "the calling process already has a connection"
    after
      Redix.command(seed, ["DEL", key])
      GenServer.stop(seed)
    end
  end

  test "does not lease a connection that fails to start" do
    name = :failed_connection_pool_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 1, sync_connect: true],
        databases: [10]
      )

    assert {:error,
            %RedixSandbox.CheckoutError{
              sandbox: ^name,
              database: 10,
              operation: :connection_start,
              reason: %Redix.ConnectionError{},
              message: message
            }} = RedixSandbox.checkout(name)

    assert message =~ "starting the Redis connection failed for database 10"

    assert %{available: [_connection], leases: %{}} =
             Process.whereis(RedixSandbox.Names.pool(name)) |> :sys.get_state()

    assert_raise RedixSandbox.NotCheckedOutError, fn ->
      Redix.command(RedixSandbox.via(name), ["PING"])
    end
  end

  test "does not lease a connection when FLUSHDB fails" do
    name = :flush_failed_pool_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [
          host: "127.0.0.1",
          port: 6379,
          username: "redix_sandbox_no_flush",
          password: "no-flush-password"
        ],
        databases: [9]
      )

    assert {:error,
            %RedixSandbox.CheckoutError{
              sandbox: ^name,
              database: 9,
              operation: :flush,
              reason: %Redix.Error{message: reason},
              message: message
            }} = RedixSandbox.checkout(name)

    assert reason =~ "NOPERM"
    assert message =~ "FLUSHDB failed for database 9"

    assert %{available: [_connection], leases: %{}} =
             Process.whereis(RedixSandbox.Names.pool(name)) |> :sys.get_state()
  end

  test "clears ownership when the pool crashes" do
    name = :pool_crash_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [6]
      )

    assert :ok = RedixSandbox.checkout(name)
    pool = Process.whereis(RedixSandbox.Names.pool(name))
    monitor = Process.monitor(pool)
    Process.exit(pool, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pool, :killed}

    assert_eventually_not_checked_out(name)

    assert :ok = RedixSandbox.checkout(name)
    assert {:ok, "PONG"} = Redix.command(RedixSandbox.via(name), ["PING"])
  end

  @spec assert_eventually_not_checked_out(RedixSandbox.name(), non_neg_integer()) :: :ok
  defp assert_eventually_not_checked_out(name, attempts \\ 50)

  defp assert_eventually_not_checked_out(_name, 0),
    do: flunk("expected ownership to clear after the pool restarted")

  defp assert_eventually_not_checked_out(name, attempts) do
    try do
      Redix.command(RedixSandbox.via(name), ["PING"])
      Process.sleep(10)
      assert_eventually_not_checked_out(name, attempts - 1)
    rescue
      RedixSandbox.NotCheckedOutError ->
        :ok
    catch
      :exit, _reason ->
        Process.sleep(10)
        assert_eventually_not_checked_out(name, attempts - 1)
    end
  end

  test "reports and recovers a checked-out connection that exits" do
    name = :restarted_connection_pool_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [11]
      )

    connection = connection(name)
    assert :ok = RedixSandbox.checkout(name)
    connection_pid = Process.whereis(connection.name)
    connection_supervisor = RedixSandbox.Names.connection_supervisor(name)
    monitor = Process.monitor(connection_pid)

    :sys.suspend(connection_supervisor)

    try do
      Process.exit(connection_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^connection_pid, :killed}

      assert_raise RedixSandbox.ConnectionUnavailableError,
                   ~r/connection for checked-out sandbox :restarted_connection_pool_test is unavailable/,
                   fn ->
                     Redix.command(RedixSandbox.via(name), ["PING"])
                   end
    after
      :sys.resume(connection_supervisor)
    end

    assert_eventually_ping(connection.name)
    assert {:ok, "PONG"} = Redix.command(RedixSandbox.via(name), ["PING"])
    refute Process.whereis(connection.name) == connection_pid
  end

  test "returns a crashed owner's database to the pool" do
    name = :released_pool_test
    parent = self()

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [12]
      )

    owner =
      spawn(fn ->
        send(parent, {:checked_out, self(), RedixSandbox.checkout(name)})
        Process.sleep(:infinity)
      end)

    assert_receive {:checked_out, ^owner, :ok}

    assert {:error,
            %RedixSandbox.CheckoutError{
              sandbox: ^name,
              database: nil,
              operation: :checkout,
              reason: :pool_exhausted,
              message: message
            }} = RedixSandbox.checkout(name)

    assert message =~ "no logical Redis database is available"

    connection = %{name: RedixSandbox.Names.connection(name, 12)}
    connection_pid = Process.whereis(connection.name)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert_eventually_checkout(name)
    assert Process.whereis(connection.name) == connection_pid
  end

  @spec assert_eventually_ping(atom(), non_neg_integer()) :: :ok
  defp assert_eventually_ping(connection_name, attempts \\ 50)

  defp assert_eventually_ping(_connection_name, 0),
    do: flunk("expected the restarted connection to respond to PING")

  defp assert_eventually_ping(connection_name, attempts) do
    case Process.whereis(connection_name) do
      nil ->
        Process.sleep(10)
        assert_eventually_ping(connection_name, attempts - 1)

      pid ->
        case Redix.command(pid, ["PING"]) do
          {:ok, "PONG"} ->
            :ok

          _result ->
            Process.sleep(10)
            assert_eventually_ping(connection_name, attempts - 1)
        end
    end
  end

  @spec assert_eventually_checkout(RedixSandbox.name(), non_neg_integer()) :: :ok
  defp assert_eventually_checkout(name, attempts \\ 50)

  defp assert_eventually_checkout(_name, 0),
    do: flunk("expected the database to return to the pool")

  defp assert_eventually_checkout(name, attempts) do
    case RedixSandbox.checkout(name) do
      :ok ->
        :ok

      {:error, %RedixSandbox.CheckoutError{reason: :pool_exhausted}} ->
        Process.sleep(10)
        assert_eventually_checkout(name, attempts - 1)
    end
  end

  @spec connection(RedixSandbox.name()) :: map()
  defp connection(name) do
    Process.whereis(RedixSandbox.Names.pool(name))
    |> :sys.get_state()
    |> Map.fetch!(:available)
    |> List.first()
  end
end
