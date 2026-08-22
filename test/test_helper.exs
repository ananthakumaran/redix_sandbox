ExUnit.start()

{:ok, _pid} =
  RedixSandbox.start_link(
    name: :redix,
    connection: [host: "127.0.0.1", port: 6379],
    databases: 1..5
  )

{:ok, _pid} = RedixSandbox.DetachedExecutor.start_link()
