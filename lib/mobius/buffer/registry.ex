defmodule Mobius.Buffer.Registry do
  @moduledoc false

  def name(instance_name), do: Module.concat(__MODULE__, instance_name)

  def via_name(instance_name, _resolution) when is_pid(instance_name), do: instance_name

  def via_name(instance_name, resolution) do
    {:via, Registry, {name(instance_name), resolution}}
  end
end
