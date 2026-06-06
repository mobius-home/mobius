defmodule Mobius.DDSketch do
  @moduledoc """
  A sparse, mergeable quantile sketch with bounded relative error.

  Properties Mobius relies on:

    * **Ingress-time aggregation.** Each value maps to a bin counter at
      observation time — no time-bucketing.
    * **Mergeable.** Bin counters sum across windows, so window queries
      are bin-by-bin subtraction of two snapshots.
    * **Bounded memory.** Bin count grows with the diversity of observed
      magnitudes, not with uptime.
    * **Clock-invariant.** Bin indices are value-derived; wall-clock
      drift can't corrupt the structure.

  Each populated bin is one integer counter:

      %Mobius.DDSketch{
        relative_accuracy: 0.1,
        zero_count: 12,
        positive_bins: %{42 => 3, 43 => 17},
        negative_bins: %{}
      }

  `bins/1` projects to a list of `{bin_key, count}` pairs for storage,
  `from_bins/2` reconstructs.

  ## Configuration

  Pick `:relative_accuracy` (α): the relative error bound on any
  quantile estimate. Default 0.1 (±10%). Smaller α produces more bins.
  α can't change after the sketch has data — bin indices depend on it.

  Values below `:min_indexable_value` fold into the zero bucket. Values
  above `:max_indexable_value` clamp to the top bin (default) or drop
  (`:on_overflow: :drop`).
  """

  @default_relative_accuracy 0.1
  @default_min_indexable_value 1.0e-9
  @default_max_indexable_value 1.0e18
  @default_on_overflow :clamp
  @valid_on_overflow [:clamp, :drop]
  @valid_opt_keys [:relative_accuracy, :min_indexable_value, :max_indexable_value, :on_overflow]

  @typedoc """
  Index of a positive or negative bin. Derived from the value's magnitude
  and the sketch's `:relative_accuracy`.
  """
  @type bin_index() :: integer()

  @typedoc """
  Sparse map from bin index to observation count.
  """
  @type bin_map() :: %{bin_index() => pos_integer()}

  @typedoc """
  An ETS-friendly identifier for one bin counter.
  """
  @type bin_key() ::
          {:hist, :pos, bin_index()}
          | {:hist, :neg, bin_index()}
          | {:hist, :zero}

  @typedoc """
  What to do with an observation whose magnitude exceeds
  `:max_indexable_value`.

    * `:clamp` — map the value to the top bin (saturate). The histogram
      keeps counting; quantiles above the configured range collapse to
      the top bin's estimator. This is the default and matches how
      Prometheus and HdrHistogram handle the tail.
    * `:drop` — silently skip the observation. Use only when you would
      rather have an under-count than let outliers register at the top
      of the distribution.
  """
  @type on_overflow() :: :clamp | :drop

  @type t() :: %__MODULE__{
          relative_accuracy: float(),
          min_indexable_value: float(),
          max_indexable_value: float(),
          on_overflow: on_overflow(),
          gamma: float(),
          log_gamma: float(),
          max_positive_index: integer(),
          zero_count: non_neg_integer(),
          positive_bins: bin_map(),
          negative_bins: bin_map()
        }

  defstruct relative_accuracy: @default_relative_accuracy,
            min_indexable_value: @default_min_indexable_value,
            max_indexable_value: @default_max_indexable_value,
            on_overflow: @default_on_overflow,
            gamma: nil,
            log_gamma: nil,
            max_positive_index: nil,
            zero_count: 0,
            positive_bins: %{},
            negative_bins: %{}

  @doc """
  Create a new, empty sketch.

  Options:

    * `:relative_accuracy` — α, the bound on relative quantile error.
      Number in (0, 1). Defaults to `#{@default_relative_accuracy}`.
    * `:min_indexable_value` — values whose magnitude is below this fold
      into the zero bucket. Defaults to `#{@default_min_indexable_value}`.
    * `:max_indexable_value` — values whose magnitude exceeds this
      clamp to the top bin (or drop). Defaults to
      `#{@default_max_indexable_value}`; tighten to cap bin growth.
    * `:on_overflow` — `:clamp` (default) or `:drop`. See `t:on_overflow/0`.

  Integer values are accepted and cast to floats. Raises `ArgumentError`
  on invalid options; use `validate_opts/1` for a non-raising check.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    case validate_opts(opts) do
      {:ok, validated} -> build(validated)
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Validate and normalize sketch options without raising.

  Integer values for `:relative_accuracy`, `:min_indexable_value`, and
  `:max_indexable_value` are cast to floats. Returns the normalized
  option list with every option filled in, or `{:error, message}`
  describing the first problem found — including unknown option keys,
  which would otherwise be silently ignored and leave a misconfiguration
  undetected.
  """
  @spec validate_opts(term()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_opts(opts) do
    if Keyword.keyword?(opts) do
      do_validate_opts(opts)
    else
      {:error, "sketch options must be a keyword list, got: #{inspect(opts)}"}
    end
  end

  defp do_validate_opts(opts) do
    alpha = opts |> Keyword.get(:relative_accuracy, @default_relative_accuracy) |> to_float()
    min_v = opts |> Keyword.get(:min_indexable_value, @default_min_indexable_value) |> to_float()
    max_v = opts |> Keyword.get(:max_indexable_value, @default_max_indexable_value) |> to_float()
    on_overflow = Keyword.get(opts, :on_overflow, @default_on_overflow)

    with :ok <- validate_known_keys(opts),
         :ok <- validate_alpha(alpha),
         :ok <- validate_min(min_v),
         :ok <- validate_max(max_v, min_v),
         :ok <- validate_on_overflow(on_overflow) do
      {:ok,
       [
         relative_accuracy: alpha,
         min_indexable_value: min_v,
         max_indexable_value: max_v,
         on_overflow: on_overflow
       ]}
    end
  end

  defp validate_known_keys(opts) do
    case Keyword.keys(opts) -- @valid_opt_keys do
      [] -> :ok
      unknown -> {:error, "unknown sketch options: #{inspect(unknown)}"}
    end
  end

  defp validate_alpha(alpha) when is_float(alpha) and alpha > 0.0 and alpha < 1.0, do: :ok

  defp validate_alpha(alpha) do
    {:error, "relative_accuracy must be a number in (0, 1), got: #{inspect(alpha)}"}
  end

  defp validate_min(min_v) when is_float(min_v) and min_v > 0.0, do: :ok

  defp validate_min(min_v) do
    {:error, "min_indexable_value must be a positive number, got: #{inspect(min_v)}"}
  end

  defp validate_max(max_v, min_v) when is_float(max_v) and max_v > min_v, do: :ok

  defp validate_max(max_v, _min_v) do
    {:error,
     "max_indexable_value must be a number greater than min_indexable_value, " <>
       "got: #{inspect(max_v)}"}
  end

  defp validate_on_overflow(on_overflow) when on_overflow in @valid_on_overflow, do: :ok

  defp validate_on_overflow(on_overflow) do
    {:error,
     "on_overflow must be one of #{inspect(@valid_on_overflow)}, got: #{inspect(on_overflow)}"}
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value), do: value

  # Build a sketch from options already normalized by validate_opts/1.
  defp build(opts) do
    alpha = Keyword.fetch!(opts, :relative_accuracy)
    max_v = Keyword.fetch!(opts, :max_indexable_value)

    gamma = (1.0 + alpha) / (1.0 - alpha)
    log_gamma = :math.log(gamma)

    %__MODULE__{
      relative_accuracy: alpha,
      min_indexable_value: Keyword.fetch!(opts, :min_indexable_value),
      max_indexable_value: max_v,
      on_overflow: Keyword.fetch!(opts, :on_overflow),
      gamma: gamma,
      log_gamma: log_gamma,
      max_positive_index: ceil(:math.log(max_v) / log_gamma)
    }
  end

  @doc """
  Insert a single observation into the sketch.
  """
  @spec insert(t(), number()) :: t()
  def insert(%__MODULE__{} = sketch, value) do
    insert_n(sketch, value, 1)
  end

  @doc """
  Insert `count` observations of `value`.

  For batched writes or reconstructing a sketch from already-aggregated
  counts.
  """
  @spec insert_n(t(), number(), pos_integer()) :: t()
  def insert_n(%__MODULE__{} = sketch, value, count)
      when is_number(value) and is_integer(count) and count > 0 do
    value = value * 1.0

    cond do
      abs(value) < sketch.min_indexable_value -> bump_zero(sketch, count)
      value > 0 -> bump_region(sketch, :positive, value, count)
      true -> bump_region(sketch, :negative, -value, count)
    end
  end

  defp bump_zero(sketch, count), do: %{sketch | zero_count: sketch.zero_count + count}

  defp bump_region(sketch, region, magnitude, count) do
    case resolve_index(magnitude, sketch) do
      :drop -> sketch
      {:ok, idx} -> update_region_bins(sketch, region, idx, count)
    end
  end

  defp update_region_bins(sketch, :positive, idx, count) do
    %{sketch | positive_bins: bump(sketch.positive_bins, idx, count)}
  end

  defp update_region_bins(sketch, :negative, idx, count) do
    %{sketch | negative_bins: bump(sketch.negative_bins, idx, count)}
  end

  defp bump(bin_map, idx, count) do
    Map.update(bin_map, idx, count, &(&1 + count))
  end

  # Returns {:ok, idx} for a value that should be recorded, or :drop for
  # an over-max value with :on_overflow == :drop.
  defp resolve_index(magnitude, %__MODULE__{} = sketch) do
    cond do
      magnitude <= sketch.max_indexable_value ->
        {:ok, ceil(:math.log(magnitude) / sketch.log_gamma)}

      sketch.on_overflow == :clamp ->
        {:ok, sketch.max_positive_index}

      true ->
        :drop
    end
  end

  @doc """
  Merge two sketches into one by summing bin counters.

  Both sketches must share the same `:relative_accuracy`. Other sketch
  parameters are taken from the first argument.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{relative_accuracy: a} = s1, %__MODULE__{relative_accuracy: a} = s2) do
    %{
      s1
      | zero_count: s1.zero_count + s2.zero_count,
        positive_bins: merge_bin_maps(s1.positive_bins, s2.positive_bins),
        negative_bins: merge_bin_maps(s1.negative_bins, s2.negative_bins)
    }
  end

  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    raise ArgumentError,
          "cannot merge sketches with different relative_accuracy " <>
            "(#{a.relative_accuracy} vs #{b.relative_accuracy})"
  end

  defp merge_bin_maps(left, right) do
    Map.merge(left, right, fn _idx, lc, rc -> lc + rc end)
  end

  @doc """
  Total observation count across all bins.
  """
  @spec total_count(t()) :: non_neg_integer()
  def total_count(%__MODULE__{} = sketch) do
    sketch.zero_count + sum_counts(sketch.positive_bins) + sum_counts(sketch.negative_bins)
  end

  @doc """
  Whether this sketch has any observations.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = sketch), do: total_count(sketch) == 0

  defp sum_counts(bin_map) do
    Enum.reduce(bin_map, 0, fn {_idx, c}, acc -> acc + c end)
  end

  @doc """
  Estimate the value at quantile `q` (0.0–1.0).

  Returns `nil` for an empty sketch. The returned value is within
  `:relative_accuracy` of every value that could have landed in the chosen
  bin.
  """
  @spec quantile(t(), float()) :: float() | nil
  def quantile(%__MODULE__{} = sketch, q) when is_number(q) and q >= 0.0 and q <= 1.0 do
    total = total_count(sketch)

    if total == 0 do
      nil
    else
      rank = q * (total - 1)
      pick_at_rank(ordered_entries(sketch), rank)
    end
  end

  @doc """
  Batch version of `quantile/2`. Returns `%{q => value}`.

  Walks the ordered entry list once per quantile rather than rebuilding
  it for each call — cheaper than repeated `quantile/2` calls when the
  bin set is large.
  """
  @spec quantiles(t(), [float()]) :: %{float() => float() | nil}
  def quantiles(%__MODULE__{} = sketch, qs) when is_list(qs) do
    Enum.each(qs, &validate_quantile!/1)
    total = total_count(sketch)

    if total == 0 do
      Map.new(qs, fn q -> {q, nil} end)
    else
      entries = ordered_entries(sketch)
      Map.new(qs, fn q -> {q, pick_at_rank(entries, q * (total - 1))} end)
    end
  end

  defp validate_quantile!(q) when is_number(q) and q >= 0.0 and q <= 1.0, do: :ok

  defp validate_quantile!(q) do
    raise ArgumentError, "quantile must be a number in [0.0, 1.0], got: #{inspect(q)}"
  end

  @doc """
  Smallest value estimate in the sketch, or `nil` if empty.
  """
  @spec min(t()) :: float() | nil
  def min(%__MODULE__{} = sketch) do
    case ordered_entries(sketch) do
      [] -> nil
      [{value, _count} | _] -> value
    end
  end

  @doc """
  Largest value estimate in the sketch, or `nil` if empty.
  """
  @spec max(t()) :: float() | nil
  def max(%__MODULE__{} = sketch) do
    case ordered_entries(sketch) |> List.last() do
      nil -> nil
      {value, _count} -> value
    end
  end

  @doc """
  Count of observations whose value is strictly less than `threshold`.

  For SLO-style queries — "how many requests met the 200 ms budget?"
  """
  @spec count_below(t(), number()) :: non_neg_integer()
  def count_below(%__MODULE__{} = sketch, threshold) when is_number(threshold) do
    count_in_range(sketch, :neg_inf, threshold, include_lo: true, include_hi: false)
  end

  @doc """
  Number of observations whose value is strictly greater than `threshold`.
  """
  @spec count_above(t(), number()) :: non_neg_integer()
  def count_above(%__MODULE__{} = sketch, threshold) when is_number(threshold) do
    count_in_range(sketch, threshold, :pos_inf, include_lo: false, include_hi: true)
  end

  @doc """
  Number of observations whose value lies in `[lo, hi]` (inclusive).
  """
  @spec count_between(t(), number(), number()) :: non_neg_integer()
  def count_between(%__MODULE__{} = sketch, lo, hi)
      when is_number(lo) and is_number(hi) and lo <= hi do
    count_in_range(sketch, lo, hi, include_lo: true, include_hi: true)
  end

  @doc """
  The populated bins as `{representative_value, count}` pairs, ascending by value.

  This is the same bin walk `quantile/1` uses, exposed so callers can read a
  sketch's distribution without coupling to the internal bin-key format or the
  `gamma` field.

  Ordering is ascending by representative value. The representative value of a
  positive bin of index `k` is the canonical DDSketch within-bin estimator
  `2·gamma^k / (gamma + 1)`; the zero bucket reports `0.0`, and negative bins
  are the mirrored negatives of their positive-index counterparts. Counts are
  exact integers; the representative values carry the sketch's relative-accuracy
  error (each is within `relative_accuracy` of every value in its bin).

      iex> sketch = Mobius.DDSketch.new()
      iex> sketch = Enum.reduce([10.0, 10.0, 1000.0], sketch, &Mobius.DDSketch.insert(&2, &1))
      iex> [{v1, 2}, {_v2, 1}] = Mobius.DDSketch.bin_estimates(sketch)
      iex> abs(v1 - 10.0) / 10.0 <= sketch.relative_accuracy
      true
  """
  @spec bin_estimates(t()) :: [{float(), pos_integer()}]
  def bin_estimates(%__MODULE__{} = sketch) do
    ordered_entries(sketch)
  end

  defp count_in_range(sketch, lo, hi, opts) do
    include_lo = Keyword.fetch!(opts, :include_lo)
    include_hi = Keyword.fetch!(opts, :include_hi)

    sketch
    |> ordered_entries()
    |> Enum.reduce(0, fn {value, count}, acc ->
      if in_range?(value, lo, include_lo, hi, include_hi), do: acc + count, else: acc
    end)
  end

  defp in_range?(value, lo, include_lo, hi, include_hi) do
    above_lo?(value, lo, include_lo) and below_hi?(value, hi, include_hi)
  end

  defp above_lo?(_value, :neg_inf, _include), do: true
  defp above_lo?(value, lo, true), do: value >= lo
  defp above_lo?(value, lo, false), do: value > lo

  defp below_hi?(_value, :pos_inf, _include), do: true
  defp below_hi?(value, hi, true), do: value <= hi
  defp below_hi?(value, hi, false), do: value < hi

  @doc """
  Project the sketch to a list of `{bin_key, count}` pairs.

  Each entry maps onto one ETS counter row. The ordering of the returned
  list is unspecified.
  """
  @spec bins(t()) :: [{bin_key(), pos_integer()}]
  def bins(%__MODULE__{} = sketch) do
    zero = if sketch.zero_count > 0, do: [{{:hist, :zero}, sketch.zero_count}], else: []
    pos = Enum.map(sketch.positive_bins, fn {idx, c} -> {{:hist, :pos, idx}, c} end)
    neg = Enum.map(sketch.negative_bins, fn {idx, c} -> {{:hist, :neg, idx}, c} end)
    zero ++ pos ++ neg
  end

  @doc """
  Map a value to the `bin_key` it would land in.

  Used by ingress to know which ETS row to increment. Returns the
  top-bin key for over-max values when `:on_overflow` is `:clamp` (the
  default), or `:drop` when `:on_overflow` is `:drop`.
  """
  @spec bin_key_for_value(t(), number()) :: bin_key() | :drop
  def bin_key_for_value(%__MODULE__{} = sketch, value) when is_number(value) do
    value = value * 1.0

    cond do
      abs(value) < sketch.min_indexable_value ->
        {:hist, :zero}

      value > 0 ->
        case resolve_index(value, sketch) do
          {:ok, idx} -> {:hist, :pos, idx}
          :drop -> :drop
        end

      true ->
        case resolve_index(-value, sketch) do
          {:ok, idx} -> {:hist, :neg, idx}
          :drop -> :drop
        end
    end
  end

  @doc """
  Reconstruct a sketch from a list of `{bin_key, count}` pairs.

  `opts` are passed to `new/1` and **must** match the original sketch's
  `:relative_accuracy` — bin indices depend on it, so a mismatch produces
  wrong quantile estimates.
  """
  @spec from_bins(keyword(), [{bin_key(), non_neg_integer()}]) :: t()
  def from_bins(opts, bins) when is_list(bins) do
    Enum.reduce(bins, new(opts), fn
      {_key, 0}, sketch ->
        sketch

      {{:hist, :zero}, count}, sketch when count > 0 ->
        %{sketch | zero_count: sketch.zero_count + count}

      {{:hist, :pos, idx}, count}, sketch when count > 0 ->
        %{sketch | positive_bins: bump(sketch.positive_bins, idx, count)}

      {{:hist, :neg, idx}, count}, sketch when count > 0 ->
        %{sketch | negative_bins: bump(sketch.negative_bins, idx, count)}
    end)
  end

  @typedoc """
  Point-in-time capture of one sketch's bin state: a tuple of
  `{positive_bins, negative_bins, zero_count}`.

  This is the per-metric histogram payload stored in each Mobius RRD
  scrape. At rest it is encoded with `:erlang.term_to_binary/1` — one
  opaque binary per metric series — so the retained snapshots stay
  compact and off the owning process heap.
  """
  @type snapshot() ::
          {%{integer() => pos_integer()}, %{integer() => pos_integer()}, non_neg_integer()}

  @doc """
  Reconstruct a sketch directly from a stored snapshot.

  Accepts either the raw `t:snapshot/0` tuple or its
  `:erlang.term_to_binary/1` encoding (the at-rest form).

  This is the cheap path used by window queries: the snapshot already
  mirrors the sketch's internal bin layout, so a single struct update
  produces the sketch — no per-bin work. `opts` must match the original
  sketch's configuration (most importantly `:relative_accuracy`).
  """
  @spec from_snapshot(keyword(), snapshot() | binary()) :: t()
  def from_snapshot(opts, binary) when is_binary(binary) do
    from_snapshot(opts, :erlang.binary_to_term(binary))
  end

  def from_snapshot(opts, {positive_bins, negative_bins, zero_count})
      when is_map(positive_bins) and is_map(negative_bins) and is_integer(zero_count) do
    %{
      new(opts)
      | positive_bins: positive_bins,
        negative_bins: negative_bins,
        zero_count: zero_count
    }
  end

  @doc """
  Compute the bin-by-bin difference `later - earlier`.

  Used to materialise a window sketch from two RRD snapshots. Both
  sketches must share the same `:relative_accuracy` (mismatched
  accuracies raise — that is a caller bug). Bins that net to zero drop
  out.

  Returns `{:ok, sketch}`, or `{:error, :reset}` when any per-bin delta
  is negative. Counters are cumulative and monotonically nondecreasing
  within a series, so a negative delta means the accumulator was reset
  between the two snapshots — e.g. the live counters were lost in a
  reboot while the snapshot history survived. Callers decide how to
  degrade: skip the interval, or fall back to `later` alone (everything
  observed since the reset).
  """
  @spec delta(t(), t()) :: {:ok, t()} | {:error, :reset}
  def delta(
        %__MODULE__{relative_accuracy: a} = later,
        %__MODULE__{relative_accuracy: a} = earlier
      ) do
    with {:ok, zero} <- subtract(later.zero_count, earlier.zero_count),
         {:ok, pos} <- bin_map_delta(later.positive_bins, earlier.positive_bins),
         {:ok, neg} <- bin_map_delta(later.negative_bins, earlier.negative_bins) do
      {:ok, %{later | zero_count: zero, positive_bins: pos, negative_bins: neg}}
    end
  end

  def delta(%__MODULE__{} = a, %__MODULE__{} = b) do
    raise ArgumentError,
          "cannot diff sketches with different relative_accuracy " <>
            "(#{a.relative_accuracy} vs #{b.relative_accuracy})"
  end

  defp bin_map_delta(later, earlier) do
    keys = MapSet.union(MapSet.new(Map.keys(later)), MapSet.new(Map.keys(earlier)))

    Enum.reduce_while(keys, {:ok, %{}}, fn idx, {:ok, acc} ->
      case subtract(Map.get(later, idx, 0), Map.get(earlier, idx, 0)) do
        {:ok, 0} -> {:cont, {:ok, acc}}
        {:ok, diff} -> {:cont, {:ok, Map.put(acc, idx, diff)}}
        {:error, :reset} -> {:halt, {:error, :reset}}
      end
    end)
  end

  defp subtract(later, earlier) when later >= earlier, do: {:ok, later - earlier}
  defp subtract(_later, _earlier), do: {:error, :reset}

  # Walk the bin set in ascending value order and emit
  # {value_estimator, count} pairs.
  defp ordered_entries(%__MODULE__{} = sketch) do
    neg =
      sketch.negative_bins
      |> Enum.sort_by(fn {idx, _c} -> -idx end)
      |> Enum.map(fn {idx, c} -> {-bin_value(idx, sketch.gamma), c} end)

    zero =
      if sketch.zero_count > 0, do: [{0.0, sketch.zero_count}], else: []

    pos =
      sketch.positive_bins
      |> Enum.sort_by(fn {idx, _c} -> idx end)
      |> Enum.map(fn {idx, c} -> {bin_value(idx, sketch.gamma), c} end)

    neg ++ zero ++ pos
  end

  # Canonical DDSketch within-bin estimator. For a positive bin of index
  # idx with gamma γ, the bin covers (γ^(idx-1), γ^idx] and the estimator
  # 2γ^idx / (γ+1) has relative error ≤ α from every value in the bin.
  defp bin_value(idx, gamma) do
    pow = :math.pow(gamma, idx)
    2.0 * pow / (gamma + 1.0)
  end

  defp pick_at_rank(entries, rank) do
    Enum.reduce_while(entries, {0, nil}, fn {value, count}, {acc, _last} ->
      new_acc = acc + count

      if rank < new_acc do
        {:halt, value}
      else
        {:cont, {new_acc, value}}
      end
    end)
    |> case do
      value when is_float(value) -> value
      # Rank exactly at the end (e.g. q = 1.0 with floating-point rounding):
      # fall back to the last value we saw.
      {_, last} -> last
    end
  end
end
