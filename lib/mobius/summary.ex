defmodule Mobius.Summary do
  @moduledoc false

  # Summary data is accumulated with Welford's online algorithm: a running
  # mean and M2 (the sum of squared deviations from the mean) instead of raw
  # sums of values and squares. The sum-of-squares form subtracts two huge,
  # nearly equal numbers to get the variance, which loses the whole spread for
  # values like `system_time` (~10^12, a step of 1 apart) and can even go
  # negative. Welford's update only ever adds deviations from the current
  # mean, so M2 stays small, accurate and non-negative.
  #
  # The mean is kept relative to `:shift`, the accumulator's first value, so
  # the stored float is a small offset with full precision even when the
  # values themselves are ~10^12. That matters for `subtract/2`, which works
  # on the difference between two cumulative means.
  #
  # See https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance

  @typedoc """
  Calculated summary statistics
  """
  @type t() :: %{average: float(), std_dev: float(), reports: non_neg_integer()}

  @typedoc """
  A data type to store snapshot information about a summary in order
  to make calculations on at a later time
  """
  @type data() :: %{
          shift: number(),
          mean: float(),
          m2: float(),
          reports: non_neg_integer()
        }

  @doc """
  Create a new summary `data()` based off a metric value
  """
  @spec new(number()) :: data()
  def new(metric_value) do
    %{shift: metric_value, mean: 0.0, m2: 0.0, reports: 1}
  end

  @doc """
  Update a summary `data()` with new information based of a metric value
  """
  @spec update(data(), number()) :: data()
  def update(summary_data, new_metric_value) do
    %{shift: shift, mean: mean, m2: m2, reports: reports} = migrate(summary_data)

    value = new_metric_value - shift
    reports = reports + 1
    delta = value - mean
    mean = mean + delta / reports

    %{shift: shift, mean: mean, m2: m2 + delta * (value - mean), reports: reports}
  end

  @doc """
  Summary `data()` for only the reports made between two snapshots of the same
  accumulator, `earlier` and `later`

  `later` must have more reports than `earlier`. This is Chan et al.'s
  parallel combination run in reverse: `later` is `earlier` combined with the
  window, so the window's mean and M2 are solved for.
  """
  @spec subtract(data(), data()) :: data()
  def subtract(later, earlier) do
    %{shift: shift, mean: mean_l, m2: m2_l, reports: n_l} = migrate(later)
    %{shift: shift_e, mean: mean_e, m2: m2_e, reports: n_e} = migrate(earlier)

    # Snapshots of one accumulator share a shift; rebase if they do not.
    mean_e = mean_e + (shift_e - shift)

    n = n_l - n_e
    mean = mean_l + n_e * (mean_l - mean_e) / n
    delta = mean - mean_e

    # M2 of the window is the difference of two cumulative M2s, so rounding in
    # them can leave a window with no spread a hair below zero.
    m2 = max(m2_l - m2_e - delta * delta * n_e * n / n_l, 0.0)

    %{shift: shift, mean: mean, m2: m2, reports: n}
  end

  @doc """
  Run any calculations in the summary `data()` to produce a summary
  """
  @spec calculate(data()) :: t()
  def calculate(summary_data) do
    %{shift: shift, mean: mean, m2: m2, reports: reports} = migrate(summary_data)

    %{average: shift + mean, std_dev: std_dev(m2, reports), reports: reports}
  end

  defp std_dev(_m2, 1), do: 0.0
  defp std_dev(m2, n), do: :math.sqrt(m2 / (n - 1))

  # Summary data persisted by older versions of Mobius holds the running sum
  # and sum of squares (and possibly unused `:min`/`:max`). Convert it on read.
  # M2 is Σx² − (Σx)²/n; computing the numerator before dividing keeps it exact
  # when the legacy values were integers.
  defp migrate(%{accumulated: sum, accumulated_sqrd: sum_sqrd, reports: n}) do
    %{shift: 0, mean: sum / n, m2: max((n * sum_sqrd - sum * sum) / n, 0.0), reports: n}
  end

  defp migrate(%{shift: _, mean: _, m2: _, reports: _} = summary_data) do
    Map.take(summary_data, [:shift, :mean, :m2, :reports])
  end
end
