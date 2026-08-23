defmodule RedixSandbox.TestUtils do
  import ExUnit.Assertions, only: [flunk: 1]

  @spec unique_key(String.t()) :: String.t()
  def unique_key(namespace) when is_binary(namespace) do
    "redix_sandbox:#{namespace}:#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec assert_eventually_not_checked_out(RedixSandbox.name(), non_neg_integer()) :: :ok
  def assert_eventually_not_checked_out(name, attempts \\ 50)

  def assert_eventually_not_checked_out(_name, 0),
    do: flunk("expected ownership to clear after the pool restarted")

  def assert_eventually_not_checked_out(name, attempts) do
    assert_eventually_not_checked_out_fun(
      fn -> Redix.command({:via, RedixSandbox, name}, ["PING"]) end,
      attempts
    )
  end

  @spec assert_eventually_not_checked_out_fun((-> term()), non_neg_integer()) :: :ok
  def assert_eventually_not_checked_out_fun(fun, attempts \\ 50)

  def assert_eventually_not_checked_out_fun(_fun, 0),
    do: flunk("expected ownership to clear after the pool restarted")

  def assert_eventually_not_checked_out_fun(fun, attempts) do
    try do
      case fun.() do
        {:error, %RedixSandbox.Errors.NotCheckedOutError{}} ->
          :ok

        _result ->
          Process.sleep(10)
          assert_eventually_not_checked_out_fun(fun, attempts - 1)
      end
    rescue
      RedixSandbox.Errors.NotCheckedOutError ->
        :ok
    catch
      :exit, _reason ->
        Process.sleep(10)
        assert_eventually_not_checked_out_fun(fun, attempts - 1)
    end
  end

  @spec assert_eventually_ping(RedixSandbox.name(), non_neg_integer()) :: :ok
  def assert_eventually_ping(sandbox, attempts \\ 50)

  def assert_eventually_ping(_sandbox, 0),
    do: flunk("expected the restarted connection to respond to PING")

  def assert_eventually_ping(sandbox, attempts) do
    try do
      case Redix.command({:via, RedixSandbox, sandbox}, ["PING"]) do
        {:ok, "PONG"} ->
          :ok

        _result ->
          Process.sleep(10)
          assert_eventually_ping(sandbox, attempts - 1)
      end
    rescue
      RedixSandbox.Errors.ConnectionUnavailableError ->
        Process.sleep(10)
        assert_eventually_ping(sandbox, attempts - 1)
    catch
      :exit, _reason ->
        Process.sleep(10)
        assert_eventually_ping(sandbox, attempts - 1)
    end
  end

  @spec assert_eventually_checkout(RedixSandbox.name(), non_neg_integer()) :: :ok
  def assert_eventually_checkout(name, attempts \\ 50)

  def assert_eventually_checkout(_name, 0),
    do: flunk("expected the database to return to the pool")

  def assert_eventually_checkout(name, attempts) do
    case RedixSandbox.checkout(name) do
      :ok ->
        :ok

      {:error, %RedixSandbox.Errors.CheckoutError{reason: :pool_exhausted}} ->
        Process.sleep(10)
        assert_eventually_checkout(name, attempts - 1)
    end
  end
end
