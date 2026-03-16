# Installation

> #### Important {: .warning}
>
> HologramDevtools should not be used in production — make sure the dependency is `:dev` only.

## Mix installation

Add `hologram_devtools` to your list of dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:hologram_devtools, "~> 0.1.0", only: :dev}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

After you start your application, HologramDevtools will be running at `http://localhost:4008` by default.

## Igniter installation

HologramDevtools has [Igniter](https://github.com/ash-project/igniter) support — an alternative to standard mix installation. It will automatically add the dependency and update your `.gitignore`.

```bash
mix igniter.install hologram_devtools
```

## Chrome Extension

The Chrome extension gives you the ability to interact with HologramDevtools features directly alongside your application in the browser.

You can find the extension source at [hologram_devtools_extension](https://github.com/Neophen/hologram_devtools_extension).

> #### Note {: .info}
>
> The main HologramDevtools hex dependency must be added to your mix project — the browser extension alone is not enough.

## Verifying the installation

Once installed, start your application:

```bash
iex -S mix
```

You should see a log message indicating that HologramDevtools is running:

```
[info] HologramDevtools running at http://localhost:4008
```

Visit `http://localhost:4008` in your browser to see the dashboard.
