defmodule Mobius.Exports.MobiusBinaryFormat do
  @moduledoc false

  @format_version 1

  @doc """
  Turn a list of all metrics in the mobius binary format
  """
  @spec to_iodata([Mobius.metric()]) :: iodata()
  def to_iodata(metrics) do
    [@format_version, :erlang.term_to_binary(metrics, [:compressed])]
  end

  @doc """
  Parse the given binary
  """
  @spec parse(binary()) :: {:ok, [Mobius.metric()]} | {:error, Mobius.Exports.MBFParseError.t()}
  def parse(<<@format_version, metrics_bin::binary>>) do
    try do
      metrics = :erlang.binary_to_term(metrics_bin)

      if validate_metrics(metrics) do
        {:ok, metrics}
      else
        {:error, Mobius.Exports.MBFParseError.exception(:invalid_format)}
      end
    rescue
      ArgumentError ->
        {:error, Mobius.Exports.MBFParseError.exception(:corrupt)}
    end
  end

  def parse(_other) do
    {:error, Mobius.Exports.MBFParseError.exception(:invalid_format)}
  end

  defp validate_metrics(metrics) when is_list(metrics) do
    Enum.all?(metrics, fn metric ->
      Map.keys(metric) == [:name, :tags, :timestamp, :type, :value] && is_binary(metric.name) &&
        is_integer(metric.value) && is_map(metric.tags) &&
        is_integer(metric.timestamp) && is_valid_type(metric.type)
    end)
  end

  defp validate_metrics(_metrics), do: false

  defp is_valid_type(type) do
    type in [:last_value, :counter, :sum, :summary]
  end
end
