defmodule Mobius.Summary do
  @moduledoc false

  @typedoc """
  Calculated summary statistics
  """
  @type t() :: %{
          min: integer(),
          max: integer(),
          average: float(),
          std_dev: float(),
          p50: float(),
          p75: float(),
          p95: float(),
          p99: float()
        }

  @typedoc """
  A data type to store snapshot information about a summary in order
  to make calculations on at a later time
  """
  @type data() :: %{
          min: integer(),
          max: integer(),
          accumulated: integer(),
          accumulated_sqrd: integer(),
          reports: non_neg_integer(),
          t_digest: map()
        }

  @doc """
  Create a new summary `data()` based off a metric value
  """
  @spec new(integer()) :: data()
  def new(metric_value) do
    %{
      min: metric_value,
      max: metric_value,
      accumulated: metric_value,
      accumulated_sqrd: metric_value * metric_value,
      reports: 1,
      t_digest: TDigest.new() |> TDigest.update(metric_value)
    }
  end

  @doc """
  Update a summary `data()` with new information based of a metric value
  """
  @spec update(data(), integer()) :: data()
  def update(summary_data, new_metric_value) do
    %{
      min: min(summary_data.min, new_metric_value),
      max: max(summary_data.max, new_metric_value),
      accumulated: summary_data.accumulated + new_metric_value,
      accumulated_sqrd: summary_data.accumulated_sqrd + new_metric_value * new_metric_value,
      reports: summary_data.reports + 1,
      t_digest: TDigest.update(summary_data.t_digest, new_metric_value)
    }
  end

  @doc """
  Run any calculations in the summary `data()` to produce a summary
  """
  @spec calculate(data()) :: t()
  def calculate(summary_data) do
    %{
      min: summary_data.min,
      max: summary_data.max,
      average: summary_data.accumulated / summary_data.reports,
      std_dev:
        std_dev(summary_data.accumulated, summary_data.accumulated_sqrd, summary_data.reports),
      p50: percentile(summary_data.t_digest, 0.5),
      p75: percentile(summary_data.t_digest, 0.75),
      p95: percentile(summary_data.t_digest, 0.95),
      p99: percentile(summary_data.t_digest, 0.99)
    }
  end

  defp std_dev(_sum, _sum_sqrd, 1), do: 0

  # Naive algorithm. See Wikipedia
  defp std_dev(sum, sum_sqrd, n) do
    ((sum_sqrd - sum * sum / n) / (n - 1))
    |> :math.sqrt()
  end

  # Approximate percentiles using t-digest
  defdelegate percentile(t, p), to: TDigest
end
