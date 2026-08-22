# RedixSandbox

`RedixSandbox` provides isolated Redix connections for concurrent ExUnit
tests. Each test gets its own connection to a specific
[logical database](https://redis.io/docs/latest/commands/select/),
which is flushed at the start of the test.

## Installation

Add the dependency to the `deps` list in `mix.exs`:

```elixir
{:redix_sandbox, "~> 0.1.0", only: :test}
```

## Usage

Suppose your application starts a named process:
```elixir
# config/config.exs
config :my_app, redis_connection: :redis
```

```elixir
children = [
  {Redix,
   name: Application.compile_env!(:my_app, :redis_connection),
   host: "127.0.0.1",
   port: 6379}
]
```

```elixir
@redis Application.compile_env!(:my_app, :redis_connection)
def set(key, value), do: Redix.command(@redis, ["SET", key, value])
def get(key), do: Redix.command(@redis, ["GET", key])
```

To use RedixSandbox, change the connection in the test environment:

```elixir
# config/test.exs
config :my_app, :redis_connection, RedixSandbox.via(:redis)
```

Then start a named sandbox in `test/test_helper.exs`:

```elixir
ExUnit.start()

{:ok, _pid} =
  RedixSandbox.start_link(
    name: :redis,
    connection: [host: "127.0.0.1", port: 6379],
    databases: 1..5
  )
```

Check out the sandbox for each test:

```elixir
use ExUnit.Case, async: true

setup do
  :ok = RedixSandbox.checkout(:redis)
end
```

The application code can remain unchanged; it reads the test connection from
configuration and continues to call `Redix.command/2`.
