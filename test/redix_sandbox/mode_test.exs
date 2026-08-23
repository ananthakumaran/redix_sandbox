defmodule RedixSandbox.ModeTest do
  use ExUnit.Case, async: false

  alias RedixSandbox.Errors.{AllowError, CheckoutError, ModeError, NotCheckedOutError}
  alias RedixSandbox.TestUtils

  test "shared mode lets detached processes use the owner's connection" do
    owner = self()
    assert :ok = RedixSandbox.checkout(:redix)
    assert :ok = RedixSandbox.mode(:redix, {:shared, owner})
    on_exit(fn -> RedixSandbox.mode(:redix, :private) end)

    assert {:ok, "PONG"} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command(RedixSandbox.via(:redix), ["PING"])
             end)
  end

  test "shared mode requires a checkout" do
    owner = self()

    assert {:error,
            %ModeError{
              sandbox: :redix,
              mode: {:shared, ^owner},
              reason: :not_checked_out
            }} = RedixSandbox.mode(:redix, {:shared, owner})
  end

  test "does not allow processes in shared mode" do
    owner = self()
    assert :ok = RedixSandbox.checkout(:redix)
    assert :ok = RedixSandbox.mode(:redix, {:shared, owner})
    on_exit(fn -> RedixSandbox.mode(:redix, :private) end)

    assert {:error,
            %AllowError{
              reason: %NimbleOwnership.Error{reason: :cant_allow_in_shared_mode}
            }} =
             RedixSandbox.DetachedExecutor.call(fn ->
               RedixSandbox.allow(:redix, owner, self())
             end)
  end

  test "private mode restores process isolation" do
    owner = self()
    assert :ok = RedixSandbox.checkout(:redix)
    assert :ok = RedixSandbox.mode(:redix, {:shared, owner})

    assert {:ok, "PONG"} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command(RedixSandbox.via(:redix), ["PING"])
             end)

    assert :ok = RedixSandbox.mode(:redix, :private)

    assert {:error, %NotCheckedOutError{sandbox: :redix}} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command(RedixSandbox.via(:redix), ["PING"])
             end)
  end

  test "shared mode rejects another checkout" do
    owner = self()
    assert :ok = RedixSandbox.checkout(:redix)
    assert :ok = RedixSandbox.mode(:redix, {:shared, owner})
    on_exit(fn -> RedixSandbox.mode(:redix, :private) end)

    parent = self()

    {child, reference} =
      spawn_monitor(fn ->
        send(parent, {:checkout_result, RedixSandbox.checkout(:redix)})
      end)

    assert_receive {:checkout_result,
                    {:error,
                     %CheckoutError{
                       sandbox: :redix,
                       reason: :shared_mode
                     }}}

    assert_receive {:DOWN, ^reference, :process, ^child, :normal}
  end

  test "shared mode resets when its owner exits" do
    parent = self()

    {owner, reference} =
      spawn_monitor(fn ->
        :ok = RedixSandbox.checkout(:redix)
        :ok = RedixSandbox.mode(:redix, {:shared, self()})
        send(parent, :shared_mode_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :shared_mode_ready

    assert {:ok, "PONG"} =
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command(RedixSandbox.via(:redix), ["PING"])
             end)

    send(owner, :stop)
    assert_receive {:DOWN, ^reference, :process, ^owner, :normal}

    assert TestUtils.assert_eventually_not_checked_out_fun(fn ->
             RedixSandbox.DetachedExecutor.call(fn ->
               Redix.command(RedixSandbox.via(:redix), ["PING"])
             end)
           end)

    TestUtils.assert_eventually_checkout(:redix)
  end
end
