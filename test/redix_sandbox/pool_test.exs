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
    assert {:ok, "OK"} = Redix.command(RedixSandbox.via(:first_pool_test), ["SET", key, "first"])
    assert :ok = RedixSandbox.checkout(:second_pool_test)
    assert {:ok, nil} = Redix.command(RedixSandbox.via(:second_pool_test), ["GET", key])
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
      assert {:ok, nil} = Redix.command(RedixSandbox.via(name), ["GET", key])

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
            %RedixSandbox.Errors.CheckoutError{
              sandbox: ^name,
              database: 9,
              operation: :flush,
              reason: %Redix.Error{message: reason},
              message: message
            }} = RedixSandbox.checkout(name)

    assert reason =~ "NOPERM"
    assert message =~ "FLUSHDB failed for database 9"

    assert_raise RedixSandbox.Errors.NotCheckedOutError, fn ->
      Redix.command(RedixSandbox.via(name), ["PING"])
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
    assert {:ok, "PONG"} = Redix.command(RedixSandbox.via(name), ["PING"])
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
    connection_pid = GenServer.whereis(RedixSandbox.via(name))
    connection_supervisor = RedixSandbox.Names.connection_supervisor(name)
    monitor = Process.monitor(connection_pid)

    :sys.suspend(connection_supervisor)

    try do
      Process.exit(connection_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^connection_pid, :killed}

      assert_raise RedixSandbox.Errors.ConnectionUnavailableError,
                   ~r/connection for checked-out sandbox :restarted_connection_pool_test is unavailable/,
                   fn ->
                     Redix.command(RedixSandbox.via(name), ["PING"])
                   end
    after
      :sys.resume(connection_supervisor)
    end

    TestUtils.assert_eventually_ping(name)
    assert {:ok, "PONG"} = Redix.command(RedixSandbox.via(name), ["PING"])
    refute GenServer.whereis(RedixSandbox.via(name)) == connection_pid
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
end
