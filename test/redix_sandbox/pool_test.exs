defmodule RedixSandbox.PoolTest do
  use ExUnit.Case, async: true

  alias RedixSandbox.TestUtils

  test "starts named sandboxes with isolated connections" do
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

    key = TestUtils.unique_key("isolated")
    assert :ok = RedixSandbox.checkout(:first_pool_test)

    assert {:ok, "OK"} =
             Redix.command({:via, RedixSandbox, :first_pool_test}, ["SET", key, "first"])

    assert :ok = RedixSandbox.checkout(:second_pool_test)
    assert {:ok, nil} = Redix.command({:via, RedixSandbox, :second_pool_test}, ["GET", key])
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

    {:ok, seed} = Redix.start_link(host: "127.0.0.1", port: 6379, database: 13)

    try do
      assert {:ok, "OK"} = Redix.command(seed, ["SET", key, "stale value"])
      assert :ok = RedixSandbox.checkout(name)
      assert {:ok, nil} = Redix.command({:via, RedixSandbox, name}, ["GET", key])

      assert {:error,
              %RedixSandbox.Errors.CheckoutError{
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
            %RedixSandbox.Errors.CheckoutError{
              sandbox: ^name,
              database: 10,
              operation: :connection_start,
              reason: %Redix.ConnectionError{},
              message: message
            }} = RedixSandbox.checkout(name)

    assert message =~ "starting the Redis connection failed for database 10"

    assert_raise RedixSandbox.Errors.NotCheckedOutError, fn ->
      Redix.command({:via, RedixSandbox, name}, ["PING"])
    end
  end

  test "a blocked flush does not block other checkouts or connection lookups" do
    name = :concurrent_flush_pool_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [7, 8]
      )

    {:ok, connection} =
      DynamicSupervisor.start_child(
        RedixSandbox.Names.connection_supervisor(name),
        {Redix,
         host: "127.0.0.1", port: 6379, database: 7, name: RedixSandbox.Names.connection(name, 7)}
      )

    assert {:ok, "PONG"} = Redix.command(connection, ["PING"])
    :sys.suspend(connection)
    checkout = Task.async(fn -> RedixSandbox.checkout(name) end)

    try do
      pool = RedixSandbox.Names.pool(name)
      assert_eventually_reserved(pool, checkout.pid)
      assert Task.yield(checkout, 0) == nil

      assert :ok = RedixSandbox.checkout(name)
      assert {:ok, pid} = RedixSandbox.Pool.connection_for(pool, [self()])
      assert pid != connection
      assert {:ok, "PONG"} = Redix.command(pid, ["PING"])

      :sys.resume(connection)
      assert Task.await(checkout) == :ok
    after
      :sys.resume(connection)
      Task.shutdown(checkout, :brutal_kill)
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
            %RedixSandbox.Errors.CheckoutError{
              sandbox: ^name,
              database: 9,
              operation: :flush,
              reason: %Redix.Error{message: reason},
              message: message
            }} = RedixSandbox.checkout(name)

    assert reason =~ "NOPERM"
    assert message =~ "FLUSHDB failed for database 9"

    assert {:error, %RedixSandbox.Errors.CheckoutError{operation: :flush}} =
             RedixSandbox.checkout(name)

    assert_raise RedixSandbox.Errors.NotCheckedOutError, fn ->
      Redix.command({:via, RedixSandbox, name}, ["PING"])
    end
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

    TestUtils.assert_eventually_not_checked_out(name)

    assert :ok = RedixSandbox.checkout(name)
    assert {:ok, "PONG"} = Redix.command({:via, RedixSandbox, name}, ["PING"])
  end

  test "reports and recovers a checked-out connection that exits" do
    name = :restarted_connection_pool_test

    {:ok, _supervisor} =
      RedixSandbox.start_link(
        name: name,
        connection: [host: "127.0.0.1", port: 6379],
        databases: [11]
      )

    assert :ok = RedixSandbox.checkout(name)
    connection_pid = GenServer.whereis({:via, RedixSandbox, name})
    connection_supervisor = RedixSandbox.Names.connection_supervisor(name)
    monitor = Process.monitor(connection_pid)

    :sys.suspend(connection_supervisor)

    try do
      Process.exit(connection_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^connection_pid, :killed}

      assert_raise RedixSandbox.Errors.ConnectionUnavailableError,
                   ~r/connection for checked-out sandbox :restarted_connection_pool_test is unavailable/,
                   fn ->
                     Redix.command({:via, RedixSandbox, name}, ["PING"])
                   end
    after
      :sys.resume(connection_supervisor)
    end

    TestUtils.assert_eventually_ping(name)
    assert {:ok, "PONG"} = Redix.command({:via, RedixSandbox, name}, ["PING"])
    refute GenServer.whereis({:via, RedixSandbox, name}) == connection_pid
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
            %RedixSandbox.Errors.CheckoutError{
              sandbox: ^name,
              database: nil,
              operation: :checkout,
              reason: :pool_exhausted,
              message: message
            }} = RedixSandbox.checkout(name)

    assert message =~ "no logical Redis database is available"

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    TestUtils.assert_eventually_checkout(name)
  end

  defp assert_eventually_reserved(pool, owner, attempts \\ 50)

  defp assert_eventually_reserved(_pool, _owner, 0),
    do: flunk("expected the pool to reserve a database while FLUSHDB is blocked")

  defp assert_eventually_reserved(pool, owner, attempts) do
    if Map.has_key?(:sys.get_state(pool, 1000).leases, owner) do
      :ok
    else
      Process.sleep(10)
      assert_eventually_reserved(pool, owner, attempts - 1)
    end
  end
end
