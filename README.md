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
children = [
  {Redix,
   name: :redix,
   host: "127.0.0.1",
   port: 6379}
]
```

```elixir
# config/config.exs
config :my_app, redis_connection: :redis
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

## Explicit process allowances

`Task.async/1` automatically inherits its parent test's checkout. Other processes, such as
workers started under a supervisor or detached executors, may not be in the owner's caller
chain. Those processes cannot resolve `RedixSandbox.via/1` unless they are explicitly allowed.

Allow a process to use the owner's checked-out connection:

```elixir
owner = self()
{:ok, worker} = MyWorker.start_link()

:ok = RedixSandbox.checkout(:redis)
:ok = RedixSandbox.allow(:redis, owner, worker)
```

The allowed process shares the owner's logical Redis database; it does not receive a separate
lease. Allowances are removed automatically when the owner or child exits.

## Shared ownership mode

Shared mode is useful when several processes must use one checked-out connection, but their
process relationships cannot be expressed with caller tracking or explicit allowances:

```elixir
use ExUnit.Case, async: false

setup do
  :ok = RedixSandbox.checkout(:redis)
  :ok = RedixSandbox.mode(:redis, {:shared, self()})
end
```

In shared mode, every process resolves the shared owner's connection through
`RedixSandbox.via/1`. The owner must already have checked out the sandbox, and it must be the
sandbox's only active checkout. Restore private mode when needed:

```elixir
:ok = RedixSandbox.mode(:redis, :private)
```

Shared mode cannot be used with `async: true` for tests sharing the same sandbox. The mode is
global to the named sandbox rather than scoped to one test process, so concurrent tests would
share one Redis logical database and could observe or overwrite each other's data. Shared mode
also rejects additional checkouts while it is active.
