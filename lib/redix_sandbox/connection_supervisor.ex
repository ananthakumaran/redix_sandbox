defmodule RedixSandbox.ConnectionSupervisor do
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) when is_list(options) do
    DynamicSupervisor.start_link(__MODULE__, :ok, options)
  end

  @impl true
  @spec init(:ok) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
