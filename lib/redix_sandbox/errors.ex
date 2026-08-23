defmodule RedixSandbox.Errors do
  defmodule CheckoutError do
    defexception [:message, :sandbox, :database, :operation, :reason]
  end

  defmodule ConnectionUnavailableError do
    defexception [:message, :sandbox]
  end

  defmodule NotCheckedOutError do
    defexception [:message, :sandbox, :callers]
  end

  defmodule AllowError do
    defexception [:message, :sandbox, :owner, :child, :reason]
  end

  defmodule ModeError do
    defexception [:message, :sandbox, :mode, :reason]
  end
end
