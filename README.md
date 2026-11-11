# RedixSandbox

[![CI](https://github.com/ananthakumaran/redix_sandbox/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/ananthakumaran/redix_sandbox/actions/workflows/ci.yml) [![Hex.pm](https://img.shields.io/hexpm/v/redix_sandbox.svg)](https://hex.pm/packages/redix_sandbox) [![Documentation](https://img.shields.io/badge/hexdocs-release-blue.svg)](https://hexdocs.pm/redix_sandbox)

`RedixSandbox` provides isolated, process-scoped Redis connections for
concurrent [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html) tests. Each test
checks out a logical Redis database, which is flushed before use and returned
to the pool when the owner exits.

## Installation

Add `redix_sandbox` to the test dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:redix_sandbox, "~> 0.2.0", only: :test}
  ]
end
```

Then fetch the dependency with `mix deps.get`.

## Usage

Suppose application code uses a named Redix connection:

```elixir
# config/config.exs
config :my_app, :redis_connection, :redis
```

```elixir
@redis Application.compile_env!(:my_app, :redis_connection)

def set(key, value), do: Redix.command(@redis, ["SET", key, value])
def get(key), do: Redix.command(@redis, ["GET", key])
```

Use a `:via` tuple in the test environment. The tuple can be configured
directly, so no library code runs while configuration is evaluated:

```elixir
# config/test.exs
config :my_app, :redis_connection, {:via, RedixSandbox, :redis}
```

Start the sandbox once in `test/test_helper.exs`:

```elixir
ExUnit.start()

{:ok, _pid} =
  RedixSandbox.start_link(
    name: :redis,
    connection: [host: "127.0.0.1", port: 6379],
    databases: 1..5
  )
```

The `connection` options are passed to `Redix`; `databases` accepts any
enumerable of Redis logical database numbers. Check out a database in each
test:

```elixir
use ExUnit.Case, async: true

setup do
  :ok = RedixSandbox.checkout(:redis)
end
```

Application code can now continue to call `Redix.command/2` without knowing
that the connection is sandboxed.

## Processes outside the caller chain

`Task.async/1` automatically inherits its parent test's checkout. A process
started under a supervisor, or another detached process, must be explicitly
allowed to use the owner's connection:

```elixir
owner = self()
{:ok, worker} = MyWorker.start_link()

:ok = RedixSandbox.checkout(:redis)
:ok = RedixSandbox.allow(:redis, owner, worker)
```

The allowed process shares the owner's logical database. It does not receive a
separate lease, and the allowance is removed when the owner or child exits.

## Shared ownership mode

Use shared mode when several unrelated processes must resolve the same
connection and explicit allowances are not practical:

```elixir
use ExUnit.Case, async: false

setup do
  :ok = RedixSandbox.checkout(:redis)
  :ok = RedixSandbox.mode(:redis, {:shared, self()})
end
```

Restore process isolation with `RedixSandbox.mode(:redis, :private)`. Shared
mode is global to the named sandbox, so it must not be used by concurrent tests
sharing that sandbox. It also requires exactly one active checkout.

## License

This project is released under the [MIT License](LICENSE).
