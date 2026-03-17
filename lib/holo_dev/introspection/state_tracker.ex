defmodule HoloDev.Introspection.StateTracker do
  @moduledoc """
  Tracks live component state by tracing Hologram's renderer.
  Uses Erlang's tracing to capture component_registry from render_page/4 return values.
  """
  use GenServer

  @table :holo_dev_component_state

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get the current state for a page module (or all pages if nil)"
  def get_state(page_module \\ nil) do
    if page_module do
      case :ets.lookup(@table, page_module) do
        [{^page_module, state}] -> state
        [] -> nil
      end
    else
      :ets.tab2list(@table) |> Enum.into(%{})
    end
  rescue
    ArgumentError -> nil
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    setup_trace()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:trace, _pid, :return_from, {Hologram.Template.Renderer, :render_page, 4},
                   {_html, component_registry, _server}}, state) do
    process_component_registry(component_registry)
    {:noreply, state}
  end

  def handle_info({:trace, _pid, :call, {Hologram.Template.Renderer, :render_page, _args}}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp setup_trace do
    # Trace return values from Renderer.render_page/4
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern(
      {Hologram.Template.Renderer, :render_page, 4},
      [{:_, [], [{:return_trace}]}],
      [:local]
    )
  rescue
    e ->
      IO.warn("[HoloDev] Failed to setup state tracing: #{inspect(e)}")
  end

  defp process_component_registry(component_registry) when is_map(component_registry) do
    # Extract page module and state from the registry
    case Map.get(component_registry, "page") do
      %{module: page_module, struct: %{state: page_state}} ->
        # Build a map of all component states keyed by cid
        all_states =
          component_registry
          |> Enum.map(fn {cid, %{module: mod, struct: %{state: comp_state}}} ->
            {cid, %{
              module: mod |> to_string() |> String.replace_leading("Elixir.", ""),
              state: serialize_state(comp_state)
            }}
          end)
          |> Enum.into(%{})

        :ets.insert(@table, {page_module, %{
          page_state: serialize_state(page_state),
          components: all_states,
          captured_at: System.system_time(:millisecond)
        }})

        # Notify websocket clients about state update
        notify_state_update(page_module)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp process_component_registry(_), do: :ok

  defp notify_state_update(page_module) do
    mod_name = page_module |> to_string() |> String.replace_leading("Elixir.", "")

    Registry.dispatch(HoloDev.WebSocketRegistry, :clients, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:state_updated, mod_name})
      end
    end)
  rescue
    _ -> :ok
  end

  defp serialize_state(value) when is_map(value) do
    if Map.has_key?(value, :__struct__) do
      # Struct - show type and fields
      struct_name = value.__struct__ |> to_string() |> String.replace_leading("Elixir.", "")
      fields = value |> Map.from_struct() |> serialize_state()
      %{"__struct__" => struct_name, "fields" => fields}
    else
      Map.new(value, fn {k, v} -> {to_string(k), serialize_state(v)} end)
    end
  end

  defp serialize_state(value) when is_list(value) do
    Enum.map(value, &serialize_state/1)
  end

  defp serialize_state(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&serialize_state/1)
  end

  defp serialize_state(value) when is_atom(value) and value in [true, false, nil], do: value
  defp serialize_state(value) when is_atom(value), do: to_string(value)
  defp serialize_state(value) when is_binary(value), do: value
  defp serialize_state(value) when is_number(value), do: value
  defp serialize_state(value) when is_pid(value), do: inspect(value)
  defp serialize_state(value) when is_reference(value), do: inspect(value)
  defp serialize_state(value) when is_function(value), do: inspect(value)
  defp serialize_state(value), do: inspect(value)
end
