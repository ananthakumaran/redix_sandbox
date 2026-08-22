defmodule RedixSandboxTest do
  use ExUnit.Case, async: true

  @redis_options [host: "127.0.0.1", port: 6379]

  setup do
    {:ok, redix} = Redix.start_link(@redis_options)
    key = "redix_sandbox:test:#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      if Process.alive?(redix), do: Redix.command(redix, ["DEL", key])
    end)

    %{redix: redix, key: key}
  end

  test "runs Redis commands", %{redix: redix, key: key} do
    assert {:ok, "PONG"} = Redix.command(redix, ["PING"])
    assert {:ok, "OK"} = Redix.command(redix, ["SET", key, "value"])
    assert {:ok, "value"} = Redix.command(redix, ["GET", key])
    assert {:ok, 1} = Redix.command(redix, ["DEL", key])
    assert {:ok, nil} = Redix.command(redix, ["GET", key])
  end
end
