{:ok, _} = Registry.start_link(keys: :unique, name: Riptide.Stream.Registry)
ExUnit.start()
