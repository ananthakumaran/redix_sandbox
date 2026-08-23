defmodule RedixSandbox.AsyncIsolationTest do
  use ExUnit.Case, async: true

  @key "redix_sandbox:async_isolation"

  test "concurrent owners only see their own values" do
    results =
      run_concurrently(fn value, barrier ->
        set_result = Redix.command({:via, RedixSandbox, :redix}, ["SET", @key, value])
        :ok = barrier.()
        {set_result, Redix.command({:via, RedixSandbox, :redix}, ["GET", @key])}
      end)

    assert_isolated_results(results)
  end

  test "concurrent Task callers only see their parent values" do
    results =
      run_concurrently(fn value, barrier ->
        task =
          Task.async(fn ->
            set_result = Redix.command({:via, RedixSandbox, :redix}, ["SET", @key, value])
            :ok = barrier.()
            {set_result, Redix.command({:via, RedixSandbox, :redix}, ["GET", @key])}
          end)

        Task.await(task)
      end)

    assert_isolated_results(results)
  end

  test "does not resolve a checked-out connection for a detached executor" do
    assert :ok = RedixSandbox.checkout(:redix)

    assert {:ok, "PONG"} = Redix.command({:via, RedixSandbox, :redix}, ["PING"])

    result =
      RedixSandbox.DetachedExecutor.call(fn ->
        Redix.command({:via, RedixSandbox, :redix}, ["PING"])
      end)

    assert {:error, %RedixSandbox.Errors.NotCheckedOutError{sandbox: :redix, message: message}} =
             result

    assert message =~
             "Call RedixSandbox.checkout(:redix) before using the {:via, RedixSandbox, :redix} tuple"
  end

  @spec assert_isolated_results([{String.t(), term()}]) :: :ok
  defp assert_isolated_results(results) do
    assert Enum.sort(results) == [
             {"one", {{:ok, "OK"}, {:ok, "one"}}},
             {"two", {{:ok, "OK"}, {:ok, "two"}}}
           ]
  end

  @spec run_concurrently(function()) :: [{String.t(), term()}]
  defp run_concurrently(fun) do
    parent = self()

    workers =
      for value <- ["one", "two"] do
        {pid, reference} =
          spawn_monitor(fn ->
            :ok = RedixSandbox.checkout(:redix)

            barrier = fn ->
              send(parent, {:barrier, self(), value})

              receive do
                :continue -> :ok
              end
            end

            send(parent, {:result, self(), value, fun.(value, barrier)})
          end)

        {pid, reference, value}
      end

    barrier_pids =
      for {_pid, _reference, value} <- workers do
        assert_receive {:barrier, pid, ^value}
        pid
      end

    Enum.each(barrier_pids, &send(&1, :continue))

    for {pid, reference, value} <- workers do
      assert_receive {:result, ^pid, ^value, result}
      assert_receive {:DOWN, ^reference, :process, ^pid, :normal}
      {value, result}
    end
  end
end
