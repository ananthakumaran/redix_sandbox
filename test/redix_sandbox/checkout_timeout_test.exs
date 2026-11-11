defmodule RedixSandbox.CheckoutTimeoutTest do
  use ExUnit.Case, async: true

  alias RedixSandbox.Errors.CheckoutError

  setup do
    name = :checkout_timeout_test
    options = [host: "127.0.0.1", port: 6379]

    start_supervised!({RedixSandbox, name: name, connection: options, databases: [0]})

    {:ok, connection} =
      DynamicSupervisor.start_child(
        RedixSandbox.Names.connection_supervisor(name),
        {Redix, options ++ [name: RedixSandbox.Names.connection(name, 0), database: 0]}
      )

    assert {:ok, "PONG"} = Redix.command(connection, ["PING"], timeout: 1000)

    %{name: name, pool: RedixSandbox.Names.pool(name), connection: connection}
  end

  test "uses the configured pool call timeout", %{name: name, pool: pool} do
    :sys.suspend(pool)
    checkout = Task.async(fn -> catch_exit(RedixSandbox.checkout(name, timeout: 20)) end)

    try do
      owner = checkout.pid

      assert {:timeout, {GenServer, :call, [^pool, {:checkout, ^owner}, 20]}} =
               Task.await(checkout, 1000)
    after
      :sys.resume(pool)
      Task.shutdown(checkout, :brutal_kill)
    end
  end

  test "uses the configured flush timeout and releases failed checkouts", context do
    %{name: name, connection: connection} = context
    :sys.suspend(connection)

    try do
      started_at = System.monotonic_time(:millisecond)

      assert {:error,
              %CheckoutError{
                operation: :flush,
                database: 0,
                reason: %Redix.ConnectionError{reason: :timeout}
              }} = RedixSandbox.checkout(name, timeout: 100)

      assert System.monotonic_time(:millisecond) - started_at < 1000

      assert_raise RedixSandbox.Errors.NotCheckedOutError, fn ->
        RedixSandbox.whereis_name(name)
      end
    after
      :sys.resume(connection)
    end

    assert :ok = RedixSandbox.checkout(name, timeout: 1000)
  end

  test "checkout without options remains supported", %{name: name} do
    assert :ok = RedixSandbox.checkout(name)
  end

  test "can increase the flush timeout", context do
    assert_checkout_waits(context, 1000)
  end

  test "accepts an infinite timeout", context do
    assert_checkout_waits(context, :infinity)
  end

  test "rejects invalid timeout values before reserving a database", %{name: name, pool: pool} do
    for timeout <- [-1, nil, 1.5, :invalid] do
      assert_raise ArgumentError, ":timeout must be a non-negative integer or :infinity", fn ->
        RedixSandbox.checkout(name, timeout: timeout)
      end
    end

    assert :sys.get_state(pool).leases == %{}
    assert :ok = RedixSandbox.checkout(name, timeout: 1000)
  end

  defp assert_checkout_waits(%{name: name, connection: connection}, timeout) do
    :sys.suspend(connection)
    checkout = Task.async(fn -> RedixSandbox.checkout(name, timeout: timeout) end)

    try do
      assert Task.yield(checkout, 50) == nil
      :sys.resume(connection)
      assert Task.await(checkout, 1000) == :ok
    after
      :sys.resume(connection)
      Task.shutdown(checkout, :brutal_kill)
    end
  end
end
