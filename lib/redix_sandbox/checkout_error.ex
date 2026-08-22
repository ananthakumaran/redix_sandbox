defmodule RedixSandbox.CheckoutError do
  defexception [:message, :sandbox, :database, :operation, :reason]
end
