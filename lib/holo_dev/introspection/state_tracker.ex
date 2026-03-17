defmodule HoloDev.Introspection.StateTracker do
  @moduledoc """
  Tracks live component state by tracing Hologram's renderer.
  Captures the component_registry from render_page/4 and props from render_stateful_component/5.
  """
  use GenServer

  @table :holo_dev_component_state
  @props_table :holo_dev_component_props

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
    :ets.new(@props_table, [:named_table, :duplicate_bag, :public, write_concurrency: true])
    setup_trace()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(
        {:trace, pid, :call,
         {Hologram.Template.Renderer, :render_stateful_component,
          [module, props, _children, _context, _server]}},
        state
      ) do
    # Store props for this component render, keyed by the rendering process
    :ets.insert(@props_table, {pid, module, props})
    {:noreply, state}
  end

  def handle_info(
        {:trace, _pid, :return_from, {Hologram.Template.Renderer, :render_page, 4},
         {_html, component_registry, _server}},
        state
      ) do
    process_component_registry(component_registry)
    {:noreply, state}
  end

  def handle_info({:trace, _pid, :call, {Hologram.Template.Renderer, :render_page, _args}}, state) do
    # Clear props table for fresh render
    :ets.delete_all_objects(@props_table)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp setup_trace do
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    # Trace render_page/4 return values
    :erlang.trace_pattern(
      {Hologram.Template.Renderer, :render_page, 4},
      [{:_, [], [{:return_trace}]}],
      [:local]
    )

    # Trace render_stateful_component/5 calls to capture props
    :erlang.trace_pattern(
      {Hologram.Template.Renderer, :render_stateful_component, 5},
      [{:_, [], []}],
      [:local]
    )
  rescue
    e ->
      IO.warn("[HoloDev] Failed to setup state tracing: #{inspect(e)}")
  end

  defp process_component_registry(component_registry) when is_map(component_registry) do
    case Map.get(component_registry, "page") do
      %{module: page_module, struct: %{state: page_state}} ->
        # Collect all captured props from the render
        captured_props = :ets.tab2list(@props_table)

        # Build props lookup: group by module, preserving order
        props_by_cid = build_props_by_cid(captured_props, component_registry)

        # Build component instances with state and props
        instances =
          component_registry
          |> Enum.reject(fn {cid, _} -> cid == "page" end)
          |> Enum.map(fn {cid, %{module: mod, struct: %{state: comp_state}}} ->
            mod_name = mod |> to_string() |> String.replace_leading("Elixir.", "")
            props = Map.get(props_by_cid, cid, %{})

            {cid, %{
              module: mod_name,
              state: serialize_state(comp_state),
              props: serialize_state(props)
            }}
          end)
          |> Enum.into(%{})

        :ets.insert(@table, {page_module, %{
          page_state: serialize_state(page_state),
          components: instances,
          captured_at: System.system_time(:millisecond)
        }})

        notify_state_update(page_module)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp process_component_registry(_), do: :ok

  defp build_props_by_cid(captured_props, component_registry) do
    # Match captured props to registry entries by module + order
    # Group captured props by module (preserving render order)
    props_by_module =
      captured_props
      |> Enum.map(fn {_pid, module, props} -> {module, props} end)
      |> Enum.group_by(fn {mod, _props} -> mod end, fn {_mod, props} -> props end)

    # Group registry entries by module
    cids_by_module =
      component_registry
      |> Enum.reject(fn {cid, _} -> cid == "page" end)
      |> Enum.group_by(fn {_cid, %{module: mod}} -> mod end, fn {cid, _} -> cid end)

    # Match them up by position
    Enum.reduce(cids_by_module, %{}, fn {mod, cids}, acc ->
      mod_props = Map.get(props_by_module, mod, [])

      cids
      |> Enum.zip(mod_props)
      |> Enum.reduce(acc, fn {cid, props}, inner_acc ->
        # Remove internal props like :cid
        clean_props = Map.drop(props, [:cid])
        Map.put(inner_acc, cid, clean_props)
      end)
    end)
  end

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
