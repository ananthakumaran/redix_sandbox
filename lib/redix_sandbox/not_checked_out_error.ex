defmodule RedixSandbox.NotCheckedOutError do
  defexception [:message, :sandbox, :callers]
end
