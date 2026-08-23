defmodule RedixSandbox.AllowTest do
  use ExUnit.Case, async: false

  alias RedixSandbox.Errors.{AllowError, NotCheckedOutError}
  alias RedixSandbox.TestUtils

  test "allows a detached process to use the owner's connection" do
    owner = self()
    assert :ok = RedixSandbox.checkout(:redix)

    assert {:error, %NotCheckedOutError{sandbox: :redix}} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command({:via, RedixSandbox, :redix}, ["PING"])
             end)

    assert :ok =
             RedixSandbox.DetachedExecutor.call(fn ->
               RedixSandbox.allow(:redix, owner, self())
             end)

    assert {:ok, "PONG"} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command({:via, RedixSandbox, :redix}, ["PING"])
             end)
  end

  test "returns an error when the owner has not checked out the sandbox" do
    owner = self()

    assert {:error,
            %AllowError{
              sandbox: :redix,
              owner: ^owner,
              child: child,
              reason: %NimbleOwnership.Error{reason: :not_allowed}
            }} =
             RedixSandbox.DetachedExecutor.call(fn ->
               RedixSandbox.allow(:redix, owner, self())
             end)

    assert is_pid(child)
  end

  test "removes an allowance when the owner exits" do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        :ok = RedixSandbox.checkout(:redix)
        owner = self()

        :ok =
          RedixSandbox.DetachedExecutor.call(fn ->
            RedixSandbox.allow(:redix, owner, self())
          end)

        send(parent, :allowance_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :allowance_ready

    assert {:ok, "PONG"} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command({:via, RedixSandbox, :redix}, ["PING"])
             end)

    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert TestUtils.assert_eventually_not_checked_out_fun(fn ->
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command({:via, RedixSandbox, :redix}, ["PING"])
             end)
           end)

    TestUtils.assert_eventually_checkout(:redix)
  end
end
