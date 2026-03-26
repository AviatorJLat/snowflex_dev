defmodule SnowflexDev.Transport do
  @moduledoc "Behaviour for transport implementations that communicate with the Python worker."

  @type opts :: keyword()

  @callback start_link(opts()) :: GenServer.on_start()
  @callback execute(pid(), String.t(), list(), keyword()) ::
              {:ok, SnowflexDev.Result.t()} | {:error, SnowflexDev.Error.t()}
  @callback ping(pid()) :: :ok | {:error, SnowflexDev.Error.t()}
  @callback disconnect(pid()) :: :ok
end
