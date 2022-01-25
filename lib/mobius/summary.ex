defmodule Mobius.Summary do
  @moduledoc false

  @typedoc """
  Calculated summary statistics
  """
  @type t() :: %{min: integer(), max: integer(), average: integer()}

  @typedoc """
  A data type to store snapshot information about a summary in order
  to make calculations on at a later time
  """
  @type data() :: %{
          min: integer(),
          max: integer(),
          accumulated: integer(),
          reports: non_neg_integer()
        }

  @doc """
  Create a new summary `data()` based off a metric value
  """
  @spec new(integer()) :: data()
  def new(metric_value) do
    %{min: metric_value, max: metric_value, accumulated: metric_value, reports: 1}
  end

  @doc """
  Update a summary `data()` with new information based of a metric value
  """
  @spec update(data(), non_neg_integer()) :: data()
  def update(summary_data, new_metric_value) do
    %{
      min: min(summary_data.min, new_metric_value),
      max: max(summary_data.max, new_metric_value),
      accumulated: summary_data.accumulated + new_metric_value,
      reports: summary_data.reports + 1
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
      average: round(summary_data.accumulated / summary_data.reports)
    }
  end
end
