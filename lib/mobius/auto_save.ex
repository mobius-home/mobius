defmodule Mobius.AutoSave do
  @moduledoc false

  # Trivial module to call our save function on a regular basis

  use GenServer

  @spec start_link([Mobius.arg()]) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:name]))
  end

  defp name(mobius_name) do
    Module.concat(__MODULE__, mobius_name)
  end

  @impl GenServer
  def init(args) do
    state =
      args
      |> Keyword.take([:autosave_interval, :name, :persistence_dir])
      |> Enum.into(%{})

    _ = :timer.send_interval(state.autosave_interval * 1_000, self(), :auto_save)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:auto_save, state) do
    _ = Mobius.save(state.name)
    {:noreply, state}
  end
end
