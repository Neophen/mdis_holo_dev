if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.HoloDev.Install do
    @moduledoc """
    Installs HoloDev into your project.

        mix igniter.install holo_dev

    This will:
    - Add `{:holo_dev, "~> 0.1", only: :dev}` to your deps
    - Add `.holo_dev/` to your `.gitignore`
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :holo_dev,
        adds_deps: [{:holo_dev, "~> 0.1", only: :dev}]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> add_to_gitignore()
    end

    defp add_to_gitignore(igniter) do
      gitignore_path = ".gitignore"

      case Igniter.exists?(igniter, gitignore_path) do
        true ->
          Igniter.update_file(igniter, gitignore_path, fn source ->
            content = Rewrite.Source.get(source, :content)

            if String.contains?(content, ".holo_dev/") do
              source
            else
              new_content =
                String.trim_trailing(content) <> "\n\n# HoloDev\n.holo_dev/\n"

              Rewrite.Source.update(source, :content, new_content)
            end
          end)

        false ->
          Igniter.create_new_file(igniter, gitignore_path, "# HoloDev\n.holo_dev/\n")
      end
    end
  end
end
