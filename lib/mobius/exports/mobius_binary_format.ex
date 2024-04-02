defmodule Mobius.Exports.MobiusBinaryFormat do
  @moduledoc false

  alias Mobius.Exports.MBFParseError

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
    metrics = :erlang.binary_to_term(metrics_bin)

    if validate_metrics(metrics) do
      {:ok, metrics}
    else
      {:error, MBFParseError.exception(:invalid_format)}
    end
  rescue
    ArgumentError ->
      {:error, MBFParseError.exception(:corrupt)}
  end

  def parse(_other) do
    {:error, MBFParseError.exception(:invalid_format)}
  end

  defp validate_metrics(metrics) when is_list(metrics) do
    Enum.all?(metrics, fn metric ->
      Enum.all?([:name, :tags, :timestamp, :type, :value], &Map.has_key?(metric, &1)) and
        is_binary(metric.name) and
        is_integer(metric.value) and is_map(metric.tags) and
        is_integer(metric.timestamp) and valid_type?(metric.type)
    end)
  end

  defp validate_metrics(_metrics), do: false

  defp valid_type?(type) do
    type in [:last_value, :counter, :sum, :summary]
  end
end
