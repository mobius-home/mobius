defmodule Mobius.Summary do
  @moduledoc false

  @typedoc """
  Calculated summary statistics
  """
  @type t() :: %{average: float(), std_dev: float(), reports: non_neg_integer()}

  @typedoc """
  A data type to store snapshot information about a summary in order
  to make calculations on at a later time
  """
  @type data() :: %{
          accumulated: integer(),
          accumulated_sqrd: integer(),
          reports: non_neg_integer()
        }

  @doc """
  Create a new summary `data()` based off a metric value
  """
  @spec new(integer()) :: data()
  def new(metric_value) do
    %{
      accumulated: metric_value,
      accumulated_sqrd: metric_value * metric_value,
      reports: 1
    }
  end

  @doc """
  Update a summary `data()` with new information based of a metric value
  """
  @spec update(data(), integer()) :: data()
  def update(summary_data, new_metric_value) do
    %{
      accumulated: summary_data.accumulated + new_metric_value,
      accumulated_sqrd: summary_data.accumulated_sqrd + new_metric_value * new_metric_value,
      reports: summary_data.reports + 1
    }
  end

  @doc """
  Run any calculations in the summary `data()` to produce a summary
  """
  @spec calculate(data()) :: t()
  def calculate(summary_data) do
    %{
      average: summary_data.accumulated / summary_data.reports,
      std_dev:
        std_dev(summary_data.accumulated, summary_data.accumulated_sqrd, summary_data.reports),
      reports: summary_data.reports
    }
  end

  defp std_dev(_sum, _sum_sqrd, 1), do: 0

  # Naive algorithm. See Wikipedia. Clamp the operand at 0 before sqrt: the
  # naive sum-of-squares variance can lose precision and go slightly negative
  # via catastrophic cancellation when float values flow through, which would
  # make :math.sqrt/1 raise. See FLEET_HEALTH.md.
  defp std_dev(sum, sum_sqrd, n) do
    max(0, (sum_sqrd - sum * sum / n) / (n - 1))
    |> :math.sqrt()
  end
end
