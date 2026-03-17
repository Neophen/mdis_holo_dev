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

    data =
      case Map.get(pages, id) do
        nil -> Map.get(components, id)
        page -> page
      end

    if data do
      data = Map.put(data, :id, id)

      # Try to get live state from the state tracker
      data =
        case get_live_state_for_component(id) do
          {:ok, live_state} -> Map.put(data, :state, live_state)
          :error -> data
        end

      msg = JSON.encode!(%{type: "component", data: data})
      {:push, {:text, msg}, state}
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
        layout_module = Map.get(page_info, :layoutModule)

        # Build layout node with its children
        layout_children = build_layout_children(layout_module, page_info, components, component_lookup)

        %{
          id: name,
          name: short_name(name),
          type: "page",
          route: Map.get(page_info, :route),
          file: page_info[:file],
          props: Map.get(page_info, :props, []),
          children: layout_children
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
  end

  defp build_layout_children(nil, page_info, _components, component_lookup) do
    # No layout, just return page template components
    build_template_children(page_info, component_lookup)
  end

  defp build_layout_children(layout_module_name, page_info, _components_map, component_lookup) do
    layout_info =
      case Map.get(component_lookup, short_name(layout_module_name)) do
        {_full, info} -> info
        nil -> %{}
      end

    layout_short = short_name(layout_module_name)
    layout_template_components = Map.get(layout_info, :templateComponents, [])

    # Separate Runtime from layout components (Runtime is shown at page level)
    {runtime_components, regular_layout_components} =
      Enum.split_with(layout_template_components, fn name -> name == "Runtime" end)

    runtime_nodes =
      Enum.map(runtime_components, fn name ->
        resolve_component_node(name, component_lookup)
      end)

    layout_own_children =
      Enum.map(regular_layout_components, fn comp_name ->
        resolve_component_node(comp_name, component_lookup)
      end)

    # Page template components go inside the layout (as slot content)
    page_children = build_template_children(page_info, component_lookup)

    layout_node = %{
      id: layout_module_name,
      name: layout_short,
      type: "layout",
      file: layout_info[:file],
      props: Map.get(layout_info, :props, []),
      children: layout_own_children ++ page_children
    }

    runtime_nodes ++ [layout_node]
  end

  defp build_template_children(info, component_lookup) do
    template_components = Map.get(info, :templateComponents, [])

    Enum.map(template_components, fn comp_name ->
      resolve_component_node(comp_name, component_lookup)
    end)
  end

  defp resolve_component_node(comp_name, component_lookup) do
    case Map.get(component_lookup, comp_name) do
      {full_name, info} ->
        type =
          cond do
            comp_name == "Runtime" -> "runtime"
            true -> "component"
          end

        %{
          id: full_name,
          name: comp_name,
          type: type,
          file: info[:file],
          props: Map.get(info, :props, []),
          children: []
        }

      nil ->
        # Component not found in our registry (could be a framework built-in)
        %{
          id: comp_name,
          name: comp_name,
          type: "component",
          children: []
        }
    end
  end

  defp get_live_state_for_component(module_name) do
    mod = String.to_existing_atom("Elixir." <> module_name)

    case StateTracker.get_state(mod) do
      %{page_state: page_state} ->
        {:ok, page_state}

      nil ->
        # Fallback: check if any page's component registry has this component
        all_state = StateTracker.get_state()

        result =
          Enum.find_value(all_state, fn {_page_mod, %{components: components}} ->
            Enum.find_value(components, fn {_cid, %{module: comp_mod, state: comp_state}} ->
              if comp_mod == module_name, do: comp_state
            end)
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
