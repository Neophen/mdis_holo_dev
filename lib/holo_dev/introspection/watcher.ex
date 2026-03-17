defmodule HoloDev.Introspection.Watcher do
  @moduledoc false
  use GenServer

  @retry_interval_ms 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    send(self(), :subscribe)
    {:ok, %{subscribed: false}}
  end

  @impl GenServer
  def handle_info(:subscribe, state) do
    if Process.whereis(Hologram.PubSub) do
      Phoenix.PubSub.subscribe(Hologram.PubSub, "hologram_live_reload")
      {:noreply, %{state | subscribed: true}}
    else
      Process.send_after(self(), :subscribe, @retry_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(:reload, state) do
    HoloDev.Introspection.Store.refresh()
    IO.puts("[HoloDev] Introspection updated at #{DateTime.utc_now() |> DateTime.to_iso8601()}")
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
