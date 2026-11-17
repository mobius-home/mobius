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

  defp std_dev(_sum, _sum_sqrd, 1), do: 0.0

  # Sum-of-squares variance, rearranged as (n·Σx² − (Σx)²) / (n·(n − 1)) so
  # the cancelling subtraction happens before any division. For integer
  # measurements (the common case, e.g. `system_time` or native durations)
  # both terms are exact bignums, so the difference is exact and never
  # negative. Dividing first, as the textbook form does, rounds (Σx)²/n to a
  # float and loses the whole spread once the mean is ~10^8 times the
  # standard deviation, giving 0, a wildly wrong value, or a negative number
  # that makes :math.sqrt/1 raise.
  #
  # Float measurements already lost precision when accumulated, so the
  # difference can still come out slightly negative; clamp it at 0.
  defp std_dev(sum, sum_sqrd, n) do
    max(0, (n * sum_sqrd - sum * sum) / (n * (n - 1)))
    |> :math.sqrt()
  end
end
