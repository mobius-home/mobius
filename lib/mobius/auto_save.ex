defmodule Mobius.AutoSave do
  @moduledoc false

  # Trivial module to call our save function on a regular basis

  use GenServer

  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:mobius_instance]))
  end

  defp name(instance) do
    # Builds this server's registered process name from the Mobius instance.
    # `Module.safe_concat/2` cannot be used: the resulting atom (e.g.
    # `Mobius.AutoSave.mobius`) is a synthetic registration name, not a real
    # module, so it will not already exist and `safe_concat` would raise. The
    # instance is developer-supplied config (not untrusted runtime input) and
    # the set of names is bounded, so creating the atom here is safe.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat(__MODULE__, instance)
  end

  @impl GenServer
  def init(args) do
    state =
      args
      |> Keyword.take([:autosave_interval, :mobius_instance, :persistence_dir])
      |> Enum.into(%{})

    _ = :timer.send_interval(state.autosave_interval * 1_000, self(), :auto_save)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:auto_save, state) do
    _ = Mobius.save(state.mobius_instance)
    {:noreply, state}
  end
end
