defmodule HoloDev.Web.WebSocketHandler do
  @moduledoc false
  @behaviour WebSock

  alias HoloDev.Introspection.{Store, StateTracker}

  @impl WebSock
  def init(_args) do
    # Register this process to receive introspection updates
    Registry.register(HoloDev.WebSocketRegistry, :clients, %{})
    {:ok, %{subscribed_events: false}}
  end

  @impl WebSock
  def handle_in({text, opcode: :text}, state) do
    case JSON.decode(text) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _} ->
        error = JSON.encode!(%{type: "error", data: %{message: "Invalid JSON"}})
        {:push, {:text, error}, state}
    end
  end

  def handle_in(_other, state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_info(:introspection_updated, state) do
    overview = build_overview()
    msg = JSON.encode!(%{type: "introspection_updated", data: overview})
    {:push, {:text, msg}, state}
  end

  def handle_info({:state_updated, module_name}, state) do
    live_state = StateTracker.get_state(String.to_existing_atom("Elixir." <> module_name))

    if live_state do
      msg = JSON.encode!(%{
        type: "state_updated",
        data: %{module: module_name, state: live_state}
      })
      {:push, {:text, msg}, state}
    else
      {:ok, state}
    end
  rescue
    _ -> {:ok, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSock
  def terminate(_reason, _state) do
    :ok
  end

  defp handle_message(%{"type" => "get_component_tree"} = message, state) do
    pages = Store.pages()
    components = Store.components()
    route = Map.get(message, "route")

    tree = build_component_tree(pages, components, route)
    msg = JSON.encode!(%{type: "component_tree", data: tree})
    {:push, {:text, msg}, state}
  end

  defp handle_message(%{"type" => "get_component", "id" => id}, state) do
    pages = Store.pages()
    components = Store.components()

    # Try to find component info by module name first, then by CID
    data =
      case Map.get(pages, id) do
        nil -> Map.get(components, id)
        page -> page
      end

    # If not found by module name, try to find by CID from live data
    {data, _resolved_module} =
      if data do
        {data, id}
      else
        case get_live_data_for_component(id) do
          {:ok, %{module: mod_name}} ->
            static_data = Map.get(components, mod_name, %{})
            {static_data, mod_name}
          _ ->
            {nil, id}
        end
      end

    if data do
      data = Map.put(data, :id, id)

      # Attach live state and props
      case get_live_data_for_component(id) do
        {:ok, %{state: live_state, props: live_props}} ->
          data = Map.put(data, :state, live_state)
          data = Map.put(data, :liveProps, live_props)
          msg = JSON.encode!(%{type: "component", data: data})
          {:push, {:text, msg}, state}

        {:ok, %{state: live_state}} ->
          data = Map.put(data, :state, live_state)
          msg = JSON.encode!(%{type: "component", data: data})
          {:push, {:text, msg}, state}

        _ ->
          msg = JSON.encode!(%{type: "component", data: data})
          {:push, {:text, msg}, state}
      end
    else
      msg = JSON.encode!(%{type: "error", data: %{message: "Component not found: #{id}"}})
      {:push, {:text, msg}, state}
    end
  end

  defp handle_message(%{"type" => "get_routes"}, state) do
    pages = Store.pages()

    routes =
      pages
      |> Enum.filter(fn {_name, info} -> Map.has_key?(info, :route) end)
      |> Enum.map(fn {name, info} ->
        %{
          module: name,
          route: info[:route],
          file: info[:file],
          line: info[:line]
        }
      end)
      |> Enum.sort_by(& &1.route)

    msg = JSON.encode!(%{type: "routes", data: routes})
    {:push, {:text, msg}, state}
  end

  defp handle_message(%{"type" => "get_resources"}, state) do
    resources = Store.resources()
    msg = JSON.encode!(%{type: "resources", data: resources})
    {:push, {:text, msg}, state}
  end

  defp handle_message(%{"type" => "get_overview"}, state) do
    overview = build_overview()
    msg = JSON.encode!(%{type: "overview", data: overview})
    {:push, {:text, msg}, state}
  end

  defp handle_message(%{"type" => "subscribe"}, state) do
    msg = JSON.encode!(%{type: "subscribed", data: %{message: "Subscribed to updates"}})
    {:push, {:text, msg}, %{state | subscribed_events: true}}
  end

  defp handle_message(%{"type" => type}, state) do
    msg = JSON.encode!(%{type: "error", data: %{message: "Unknown message type: #{type}"}})
    {:push, {:text, msg}, state}
  end

  defp build_overview do
    pages = Store.pages()
    components = Store.components()
    resources = Store.resources()

    %{
      version: HoloDev.version(),
      pages: map_size(pages),
      components: map_size(components),
      resources: map_size(resources)
    }
  end

  defp build_component_tree(pages, components, route) do
    # Build a lookup from short name to full component info
    component_lookup =
      components
      |> Enum.into(%{}, fn {name, info} ->
        {short_name(name), {name, info}}
      end)

    # Filter pages by route if provided
    filtered_pages =
      if route do
        Enum.filter(pages, fn {_name, info} -> Map.get(info, :route) == route end)
      else
        Enum.into(pages, [])
      end

    page_nodes =
      filtered_pages
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, page_info} ->
        page_mod = String.to_existing_atom("Elixir." <> name)
        live_data = StateTracker.get_state(page_mod)
        layout_module = Map.get(page_info, :layoutModule)

        children =
          if live_data do
            build_live_children(layout_module, live_data, components, component_lookup)
          else
            build_static_children(layout_module, page_info, component_lookup)
          end

        %{
          id: name,
          name: short_name(name),
          type: "page",
          route: Map.get(page_info, :route),
          file: page_info[:file],
          children: children
        }
      end)

    %{
      root: %{
        id: "root",
        name: "Application",
        type: "root",
        children: page_nodes
      }
    }
  rescue
    _ ->
      # Fallback to simple flat tree
      %{root: %{id: "root", name: "Application", type: "root", children: []}}
  end

  # Build tree from live component registry data
  defp build_live_children(layout_module_name, live_data, _components, component_lookup) do
    instances = Map.get(live_data, :components, %{})

    # Separate by role: layout, runtime, and regular components
    layout_cid = find_cid_for_module(instances, layout_module_name)

    {runtime_instances, other_instances} =
      instances
      |> Enum.reject(fn {cid, _} -> cid == "page" end)
      |> Enum.split_with(fn {_cid, %{module: mod}} ->
        String.ends_with?(mod, ".Runtime")
      end)

    {layout_instances, regular_instances} =
      Enum.split_with(other_instances, fn {cid, _} -> cid == layout_cid end)

    # Runtime nodes (page-level siblings of layout)
    runtime_nodes =
      Enum.map(runtime_instances, fn {cid, inst} ->
        build_instance_node(cid, inst, component_lookup, "runtime")
      end)

    # Layout node with regular components as children
    layout_nodes =
      case {layout_module_name, layout_instances} do
        {nil, _} -> []
        {_, []} ->
          # No live layout instance, use static info
          layout_info = lookup_component_info(layout_module_name, component_lookup)
          [%{
            id: layout_module_name,
            name: short_name(layout_module_name),
            type: "layout",
            file: layout_info[:file],
            children: build_regular_nodes(regular_instances, component_lookup)
          }]
        {_, [{cid, inst}]} ->
          [%{
            id: cid,
            name: short_name(inst.module),
            type: "layout",
            file: lookup_file(inst.module, component_lookup),
            children: build_regular_nodes(regular_instances, component_lookup)
          }]
      end

    runtime_nodes ++ layout_nodes
  end

  defp build_regular_nodes(instances, component_lookup) do
    Enum.map(instances, fn {cid, inst} ->
      build_instance_node(cid, inst, component_lookup, "component")
    end)
  end

  defp build_instance_node(cid, inst, component_lookup, type) do
    %{
      id: cid,
      name: short_name(inst.module),
      type: type,
      file: lookup_file(inst.module, component_lookup),
      children: []
    }
  end

  defp find_cid_for_module(_instances, nil), do: nil
  defp find_cid_for_module(instances, module_name) do
    Enum.find_value(instances, fn {cid, %{module: mod}} ->
      if mod == module_name, do: cid
    end)
  end

  defp lookup_component_info(module_name, component_lookup) do
    case Map.get(component_lookup, short_name(module_name)) do
      {_full, info} -> info
      nil -> %{}
    end
  end

  defp lookup_file(module_name, component_lookup) do
    info = lookup_component_info(module_name, component_lookup)
    info[:file]
  end

  # Fallback: static tree from template parsing (before any render happens)
  defp build_static_children(nil, page_info, component_lookup) do
    build_static_template_children(page_info, component_lookup)
  end

  defp build_static_children(layout_module_name, page_info, component_lookup) do
    layout_info = lookup_component_info(layout_module_name, component_lookup)
    layout_template_components = Map.get(layout_info, :templateComponents, [])

    {runtime_comps, regular_comps} =
      Enum.split_with(layout_template_components, fn name -> name == "Runtime" end)

    runtime_nodes = Enum.map(runtime_comps, &resolve_static_node(&1, component_lookup))
    layout_own = Enum.map(regular_comps, &resolve_static_node(&1, component_lookup))
    page_children = build_static_template_children(page_info, component_lookup)

    layout_node = %{
      id: layout_module_name,
      name: short_name(layout_module_name),
      type: "layout",
      file: layout_info[:file],
      children: layout_own ++ page_children
    }

    runtime_nodes ++ [layout_node]
  end

  defp build_static_template_children(info, component_lookup) do
    Map.get(info, :templateComponents, [])
    |> Enum.map(&resolve_static_node(&1, component_lookup))
  end

  defp resolve_static_node(comp_name, component_lookup) do
    case Map.get(component_lookup, comp_name) do
      {full_name, info} ->
        type = if comp_name == "Runtime", do: "runtime", else: "component"
        %{id: full_name, name: comp_name, type: type, file: info[:file], children: []}
      nil ->
        %{id: comp_name, name: comp_name, type: "component", children: []}
    end
  end

  # Get live state/props for a component by its CID or module name
  defp get_live_data_for_component(id) do
    all_state = StateTracker.get_state()

    # First check if it's a page module
    page_mod =
      try do
        String.to_existing_atom("Elixir." <> id)
      rescue
        _ -> nil
      end

    case page_mod && StateTracker.get_state(page_mod) do
      %{page_state: page_state} ->
        {:ok, %{state: page_state}}
      _ ->
        # Search by CID across all pages
        result =
          Enum.find_value(all_state, fn {_page_mod, %{components: components}} ->
            case Map.get(components, id) do
              %{} = inst -> inst
              nil -> nil
            end
          end)

        if result, do: {:ok, result}, else: :error
    end
  rescue
    _ -> :error
  end

  defp short_name(full_name) do
    full_name |> String.split(".") |> List.last()
  end
end
