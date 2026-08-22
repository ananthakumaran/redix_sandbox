defmodule RedixSandbox.DetachedExecutor do
  @name :redix_sandbox_detached_executor

  @spec start_link() :: {:ok, pid()}
  def start_link do
    pid = spawn_link(&loop/0)
    true = Process.register(pid, @name)
    {:ok, pid}
  end

  @spec call((-> term())) :: term()
  def call(fun) do
    reference = make_ref()
    send(@name, {self(), reference, fun})

    receive do
      {^reference, result} -> result
    after
      1_000 -> raise "detached executor did not respond"
    end
  end

  @spec loop() :: no_return()
  defp loop do
    receive do
      {sender, reference, fun} ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {kind, reason}
          end

        send(sender, {reference, result})
        loop()
    end
  end
end
