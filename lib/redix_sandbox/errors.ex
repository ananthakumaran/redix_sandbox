defmodule RedixSandbox.Errors do
  @moduledoc """
  Exceptions returned or raised by `RedixSandbox`.

  Checkout, allowance, and mode operations return these exceptions in an error
  tuple. A missing or unavailable `:via` connection raises the corresponding
  exception.
  """

  defmodule CheckoutError do
    @moduledoc "Returned when a sandbox checkout cannot be completed."

    @type t :: %__MODULE__{
            message: String.t() | nil,
            sandbox: RedixSandbox.name(),
            database: non_neg_integer() | nil,
            operation: :checkout | :connection_start | :flush,
            reason: term()
          }

    defexception [:message, :sandbox, :database, :operation, :reason]
  end

  defmodule ConnectionUnavailableError do
    @moduledoc "Raised when a checked-out Redis connection is unavailable."

    @type t :: %__MODULE__{
            message: String.t() | nil,
            sandbox: RedixSandbox.name()
          }

    defexception [:message, :sandbox]
  end

  defmodule NotCheckedOutError do
    @moduledoc "Raised when a process resolves a sandbox without checking it out."

    @type t :: %__MODULE__{
            message: String.t() | nil,
            sandbox: RedixSandbox.name(),
            callers: [pid()]
          }

    defexception [:message, :sandbox, :callers]
  end

  defmodule AllowError do
    @moduledoc "Returned when a process cannot be allowed to use a sandbox."

    @type t :: %__MODULE__{
            message: String.t() | nil,
            sandbox: RedixSandbox.name(),
            owner: pid(),
            child: pid(),
            reason: term()
          }

    defexception [:message, :sandbox, :owner, :child, :reason]
  end

  defmodule ModeError do
    @moduledoc "Returned when a sandbox ownership mode cannot be changed."

    @type t :: %__MODULE__{
            message: String.t() | nil,
            sandbox: RedixSandbox.name(),
            mode: RedixSandbox.mode(),
            reason: term()
          }

    defexception [:message, :sandbox, :mode, :reason]
  end
end
