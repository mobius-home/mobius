defmodule Mobius.DDSketchTest do
  use ExUnit.Case, async: true

  alias Mobius.DDSketch

  # Tests that don't care about the cap use the bare constructor (which
  # picks a default max). Tests that exercise the cap pass it explicitly.
  defp sketch(opts \\ []), do: DDSketch.new(opts)

  describe "new/1" do
    test "defaults are sensible" do
      s = DDSketch.new()
      assert s.relative_accuracy == 0.1
      assert s.min_indexable_value == 1.0e-9
      assert s.max_indexable_value == 1.0e18
      assert s.zero_count == 0
      assert s.positive_bins == %{}
      assert s.negative_bins == %{}
      assert s.gamma > 1.0
      assert s.log_gamma > 0.0
      assert s.on_overflow == :clamp
      assert DDSketch.empty?(s)
    end

    test "accepts a custom relative_accuracy" do
      s = sketch(relative_accuracy: 0.05)
      assert s.relative_accuracy == 0.05
      # γ = (1+α)/(1-α)
      assert_in_delta s.gamma, 1.05 / 0.95, 1.0e-12
    end

    test "rejects an out-of-range relative_accuracy" do
      assert_raise ArgumentError, fn -> sketch(relative_accuracy: 0.0) end
      assert_raise ArgumentError, fn -> sketch(relative_accuracy: 1.0) end
      assert_raise ArgumentError, fn -> sketch(relative_accuracy: -0.1) end
      assert_raise ArgumentError, fn -> sketch(relative_accuracy: 2) end
    end

    test "rejects non-positive min_indexable_value" do
      assert_raise ArgumentError, fn -> sketch(min_indexable_value: 0.0) end
      assert_raise ArgumentError, fn -> sketch(min_indexable_value: -1.0) end
    end

    test "rejects max_indexable_value not greater than min" do
      assert_raise ArgumentError, fn ->
        DDSketch.new(min_indexable_value: 1.0, max_indexable_value: 1.0)
      end
    end
  end

  describe "insert/2 and basic structure" do
    test "zero values land in zero bucket" do
      s = sketch() |> DDSketch.insert(0.0) |> DDSketch.insert(0)
      assert s.zero_count == 2
      assert s.positive_bins == %{}
      assert s.negative_bins == %{}
      assert DDSketch.total_count(s) == 2
    end

    test "sub-min values fold into zero bucket" do
      s = sketch(min_indexable_value: 1.0e-6)
      s = s |> DDSketch.insert(1.0e-9) |> DDSketch.insert(-1.0e-10)
      assert s.zero_count == 2
      assert s.positive_bins == %{}
      assert s.negative_bins == %{}
    end

    test "positive values land in positive bins" do
      s = sketch()
      s = s |> DDSketch.insert(1.0) |> DDSketch.insert(2.0) |> DDSketch.insert(100.0)
      assert s.zero_count == 0
      assert map_size(s.positive_bins) > 0
      assert s.negative_bins == %{}
      assert DDSketch.total_count(s) == 3
    end

    test "negative values land in negative bins, mirrored by magnitude" do
      s = sketch()
      s = s |> DDSketch.insert(-1.0) |> DDSketch.insert(-2.0)
      assert s.zero_count == 0
      assert s.positive_bins == %{}
      assert map_size(s.negative_bins) > 0
      assert DDSketch.total_count(s) == 2
    end

    test "the same magnitude maps to the same index for positive and negative" do
      s = sketch()
      pos_key = DDSketch.bin_key_for_value(s, 42.0)
      neg_key = DDSketch.bin_key_for_value(s, -42.0)
      assert {:hist, :pos, idx} = pos_key
      assert {:hist, :neg, ^idx} = neg_key
    end

    test "insert_n accumulates by count" do
      s = sketch() |> DDSketch.insert_n(50.0, 5)
      assert DDSketch.total_count(s) == 5
    end

    test "insert_n with non-positive count raises" do
      s = sketch()
      assert_raise FunctionClauseError, fn -> DDSketch.insert_n(s, 1.0, 0) end
      assert_raise FunctionClauseError, fn -> DDSketch.insert_n(s, 1.0, -1) end
    end

    test "integer values are accepted" do
      s = sketch() |> DDSketch.insert(1) |> DDSketch.insert(100)
      assert DDSketch.total_count(s) == 2
    end

    test "default overflow behaviour clamps over-max values to the top bin" do
      s = sketch(max_indexable_value: 1000.0)
      s = s |> DDSketch.insert(1001.0) |> DDSketch.insert(1_000_000.0)
      assert DDSketch.total_count(s) == 2
      # Both clamped values share the same bin — only one positive bin populated.
      assert map_size(s.positive_bins) == 1
    end

    test ":on_overflow :drop silently skips over-max values" do
      s = sketch(max_indexable_value: 1000.0, on_overflow: :drop)
      s = s |> DDSketch.insert(1001.0) |> DDSketch.insert(-9999.0) |> DDSketch.insert(500.0)
      assert DDSketch.total_count(s) == 1
    end

    test "clamp lands negative over-max in the top negative bin" do
      s = sketch(max_indexable_value: 1000.0)
      s = s |> DDSketch.insert(-1001.0) |> DDSketch.insert(-1_000_000.0)
      assert DDSketch.total_count(s) == 2
      assert map_size(s.negative_bins) == 1
      assert s.positive_bins == %{}
    end

    test "rejects invalid :on_overflow option" do
      assert_raise ArgumentError, fn -> sketch(on_overflow: :explode) end
    end
  end

  describe "bin_key_for_value/2" do
    test "categorises zero, sub-min, positive, negative" do
      s = sketch(min_indexable_value: 1.0e-6)
      assert DDSketch.bin_key_for_value(s, 0.0) == {:hist, :zero}
      assert DDSketch.bin_key_for_value(s, 1.0e-9) == {:hist, :zero}
      assert {:hist, :pos, _} = DDSketch.bin_key_for_value(s, 1.0)
      assert {:hist, :neg, _} = DDSketch.bin_key_for_value(s, -1.0)
    end

    test "values at the bin boundary land deterministically and never bleed across more than one bin" do
      s = sketch()
      # Bin idx covers (γ^(idx-1), γ^idx]. A value at exactly γ^idx is a
      # boundary: floating-point rounding of log(γ^idx) / log(γ) may produce
      # idx or idx+1, but it must be stable across calls and never further
      # than one bin off.
      idx_target = 50
      value_at_upper = :math.pow(s.gamma, idx_target)
      key1 = DDSketch.bin_key_for_value(s, value_at_upper)
      key2 = DDSketch.bin_key_for_value(s, value_at_upper)
      assert key1 == key2
      assert {:hist, :pos, idx} = key1
      assert idx in [idx_target, idx_target + 1]
    end
  end

  describe "quantile/2 — accuracy bound" do
    test "single value: any quantile returns that value within α relative error" do
      s = sketch() |> DDSketch.insert(100.0)
      v = DDSketch.quantile(s, 0.5)
      assert v != nil
      assert_relative_error(v, 100.0, s.relative_accuracy)
    end

    test "all-equal values produce stable quantiles within α" do
      s = Enum.reduce(1..1000, sketch(), fn _, acc -> DDSketch.insert(acc, 42.0) end)

      for q <- [0.0, 0.25, 0.5, 0.75, 0.95, 0.99, 1.0] do
        v = DDSketch.quantile(s, q)
        assert_relative_error(v, 42.0, s.relative_accuracy)
      end
    end

    test "uniform 1..10_000: quantile estimates are within α of the true quantile" do
      # Drop into a fresh sketch
      s = Enum.reduce(1..10_000, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)

      for {q, expected} <- [{0.5, 5000.5}, {0.9, 9000.1}, {0.99, 9900.01}] do
        v = DDSketch.quantile(s, q)
        # The true quantile is `expected`; the estimator is within α of the bin
        # midpoint that contains it. Use a generous bound: 2α (sketch error +
        # the discretisation of the input sequence).
        rel = abs(v - expected) / expected

        assert rel <= 2 * s.relative_accuracy,
               "q=#{q}: got #{v}, expected ~#{expected}, rel err #{rel}"
      end
    end

    test "min and max bound the distribution within α" do
      s =
        sketch()
        |> DDSketch.insert(1.0)
        |> DDSketch.insert(1000.0)

      assert_relative_error(DDSketch.quantile(s, 0.0), 1.0, s.relative_accuracy)
      assert_relative_error(DDSketch.quantile(s, 1.0), 1000.0, s.relative_accuracy)
      assert_relative_error(DDSketch.min(s), 1.0, s.relative_accuracy)
      assert_relative_error(DDSketch.max(s), 1000.0, s.relative_accuracy)
    end

    test "negative values: quantiles cross zero correctly" do
      s =
        sketch()
        |> DDSketch.insert(-100.0)
        |> DDSketch.insert(-50.0)
        |> DDSketch.insert(-10.0)
        |> DDSketch.insert(10.0)
        |> DDSketch.insert(50.0)
        |> DDSketch.insert(100.0)

      assert_relative_error(DDSketch.quantile(s, 0.0), -100.0, s.relative_accuracy)
      assert_relative_error(DDSketch.quantile(s, 1.0), 100.0, s.relative_accuracy)
      # P50 of six values spanning both signs sits at the cusp; should be one
      # of the two middle values (-10 or 10) within α.
      v = DDSketch.quantile(s, 0.5)
      assert abs(v) <= 10.0 * (1.0 + s.relative_accuracy)
    end

    test "zero bucket contributes to the count" do
      s =
        sketch()
        |> DDSketch.insert(0.0)
        |> DDSketch.insert(0.0)
        |> DDSketch.insert(0.0)
        |> DDSketch.insert(10.0)

      assert DDSketch.total_count(s) == 4
      # 3 of 4 values are zero; P50 should be 0.0
      assert DDSketch.quantile(s, 0.5) == 0.0
    end

    test "empty sketch returns nil for any quantile" do
      s = sketch()
      assert DDSketch.quantile(s, 0.0) == nil
      assert DDSketch.quantile(s, 0.5) == nil
      assert DDSketch.quantile(s, 1.0) == nil
      assert DDSketch.min(s) == nil
      assert DDSketch.max(s) == nil
    end

    test "rejects out-of-range quantile" do
      s = sketch() |> DDSketch.insert(1.0)
      assert_raise FunctionClauseError, fn -> DDSketch.quantile(s, -0.1) end
      assert_raise FunctionClauseError, fn -> DDSketch.quantile(s, 1.1) end
    end
  end

  describe "quantiles/2 (batch)" do
    test "matches per-quantile invocations" do
      s = Enum.reduce(1..500, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      qs = [0.0, 0.5, 0.9, 0.99, 1.0]
      result = DDSketch.quantiles(s, qs)

      for q <- qs do
        assert result[q] == DDSketch.quantile(s, q)
      end
    end

    test "empty sketch returns nil for every quantile" do
      s = sketch()
      assert DDSketch.quantiles(s, [0.5, 0.9]) == %{0.5 => nil, 0.9 => nil}
    end
  end

  describe "merge/2" do
    test "summing two sketches preserves total count" do
      a = Enum.reduce(1..100, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      b = Enum.reduce(101..200, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      merged = DDSketch.merge(a, b)
      assert DDSketch.total_count(merged) == 200
    end

    test "merging yields the same result as inserting both sequences into one sketch" do
      a = Enum.reduce(1..50, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      b = Enum.reduce(60..120, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      merged = DDSketch.merge(a, b)

      direct =
        (Enum.to_list(1..50) ++ Enum.to_list(60..120))
        |> Enum.reduce(sketch(), fn n, acc -> DDSketch.insert(acc, n) end)

      assert DDSketch.total_count(merged) == DDSketch.total_count(direct)

      for q <- [0.1, 0.5, 0.9, 0.99] do
        assert DDSketch.quantile(merged, q) == DDSketch.quantile(direct, q)
      end
    end

    test "rejects merge when accuracies differ" do
      a = sketch(relative_accuracy: 0.01)
      b = sketch(relative_accuracy: 0.02)
      assert_raise ArgumentError, fn -> DDSketch.merge(a, b) end
    end

    test "zero buckets are summed" do
      a = sketch() |> DDSketch.insert(0.0) |> DDSketch.insert(0.0)
      b = sketch() |> DDSketch.insert(0.0)
      merged = DDSketch.merge(a, b)
      assert merged.zero_count == 3
    end
  end

  describe "count_below / count_above / count_between" do
    setup do
      s =
        Enum.reduce(1..1000, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)

      {:ok, sketch: s}
    end

    test "count_below threshold catches roughly the right count", %{sketch: s} do
      n = DDSketch.count_below(s, 100)
      # Boundary effects: the bin containing the threshold can hold up to
      # ~2α of the data range, all of which gets attributed to one side.
      assert_in_delta(n, 99, 99 * s.relative_accuracy * 2 + 1)
    end

    test "count_above threshold catches roughly the right count", %{sketch: s} do
      n = DDSketch.count_above(s, 900)
      assert_in_delta(n, 100, 100 * s.relative_accuracy * 2 + 1)
    end

    test "count_between threshold catches roughly the right count", %{sketch: s} do
      n = DDSketch.count_between(s, 250, 750)
      assert_in_delta(n, 501, 501 * s.relative_accuracy * 2 + 1)
    end

    test "count_below 0 on a non-negative sketch returns the zero bucket only" do
      s = sketch() |> DDSketch.insert(0.0) |> DDSketch.insert(0.0) |> DDSketch.insert(1.0)
      # threshold 0: values strictly less than zero are none; but the zero bucket
      # is reported at value 0.0 which is not strictly less than 0.
      assert DDSketch.count_below(s, 0) == 0
    end

    test "count_above 0 catches everything strictly positive" do
      s = sketch() |> DDSketch.insert(0.0) |> DDSketch.insert(1.0) |> DDSketch.insert(10.0)
      assert DDSketch.count_above(s, 0) == 2
    end

    test "count_between same-value lo/hi" do
      s = sketch() |> DDSketch.insert(0.0)
      assert DDSketch.count_between(s, 0, 0) == 1
    end
  end

  describe "bins/1 and from_bins/2 (ETS round-trip)" do
    test "round-trips an empty sketch" do
      s = sketch()
      assert DDSketch.bins(s) == []
      reconstructed = DDSketch.from_bins([], DDSketch.bins(s))
      assert DDSketch.empty?(reconstructed)
    end

    test "round-trips a multi-region sketch identically" do
      s =
        sketch()
        |> DDSketch.insert(-100.0)
        |> DDSketch.insert(-100.0)
        |> DDSketch.insert(0.0)
        |> DDSketch.insert(1.0)
        |> DDSketch.insert(2.0)
        |> DDSketch.insert(2.0)
        |> DDSketch.insert(2.0)

      bins = DDSketch.bins(s)
      assert is_list(bins)
      reconstructed = DDSketch.from_bins([relative_accuracy: s.relative_accuracy], bins)

      assert reconstructed.zero_count == s.zero_count
      assert reconstructed.positive_bins == s.positive_bins
      assert reconstructed.negative_bins == s.negative_bins
      assert DDSketch.total_count(reconstructed) == DDSketch.total_count(s)
    end

    test "from_bins skips zero-count entries" do
      bins = [
        {{:hist, :pos, 42}, 0},
        {{:hist, :pos, 43}, 5},
        {{:hist, :zero}, 0}
      ]

      s = DDSketch.from_bins([], bins)
      assert s.zero_count == 0
      assert s.positive_bins == %{43 => 5}
    end

    test "bins includes the zero bucket only when it has count" do
      s = sketch() |> DDSketch.insert(1.0)
      refute Enum.any?(DDSketch.bins(s), &match?({{:hist, :zero}, _}, &1))

      s = DDSketch.insert(s, 0.0)
      assert Enum.any?(DDSketch.bins(s), &match?({{:hist, :zero}, 1}, &1))
    end

    test "bin_key_for_value matches the keys produced by bins/1 after insert" do
      s = sketch()
      key = DDSketch.bin_key_for_value(s, 123.45)
      s = DDSketch.insert(s, 123.45)
      assert {^key, 1} = hd(DDSketch.bins(s))
    end
  end

  describe "delta/2 (window reconstruction)" do
    test "later − earlier produces the per-bin window count" do
      earlier =
        Enum.reduce(1..100, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)

      later =
        Enum.reduce(101..300, earlier, fn n, acc -> DDSketch.insert(acc, n) end)

      assert {:ok, window} = DDSketch.delta(later, earlier)
      assert DDSketch.total_count(window) == 200

      # The window contents are 101..300 — quantile bounds should match.
      assert_relative_error(DDSketch.min(window), 101.0, window.relative_accuracy)
      assert_relative_error(DDSketch.max(window), 300.0, window.relative_accuracy)
    end

    test "delta of identical sketches is empty" do
      s = Enum.reduce(1..50, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      assert {:ok, window} = DDSketch.delta(s, s)
      assert DDSketch.empty?(window)
    end

    test "delta against an empty earlier returns later" do
      later = Enum.reduce(1..10, sketch(), fn n, acc -> DDSketch.insert(acc, n) end)
      empty = sketch()
      assert {:ok, window} = DDSketch.delta(later, empty)
      assert DDSketch.total_count(window) == DDSketch.total_count(later)
    end

    test "a negative bin delta reports a counter reset" do
      earlier = sketch() |> DDSketch.insert(1.0) |> DDSketch.insert(1.0)
      later = sketch() |> DDSketch.insert(1.0)

      assert {:error, :reset} = DDSketch.delta(later, earlier)
    end

    test "a reset is detected even when only the zero bucket went backwards" do
      earlier = sketch() |> DDSketch.insert(0.0) |> DDSketch.insert(0.0)
      later = sketch() |> DDSketch.insert(0.0)

      assert {:error, :reset} = DDSketch.delta(later, earlier)
    end

    test "rejects mismatched accuracies" do
      a = sketch(relative_accuracy: 0.01) |> DDSketch.insert(1.0)
      b = sketch(relative_accuracy: 0.02) |> DDSketch.insert(1.0)
      assert_raise ArgumentError, fn -> DDSketch.delta(b, a) end
    end
  end

  describe "bin count is bounded by configured range" do
    @range_low 1
    @range_high 1_000_000_000_000

    test "log-uniform random input across 12 orders of magnitude stays under the theoretical bound" do
      :rand.seed(:exsss, {1, 2, 3})

      s = sketch()

      # 12 decades from 1 .. 1_000_000_000_000.
      log_low = :math.log(@range_low)
      log_high = :math.log(@range_high)

      s =
        Enum.reduce(1..100_000, s, fn _, acc ->
          # Log-uniform: pick a value whose log is uniformly distributed.
          v = :math.exp(log_low + :rand.uniform() * (log_high - log_low))
          DDSketch.insert(acc, v)
        end)

      # Theoretical bound: ceil(log(range) / log(γ)) + 1 for boundary slack.
      bound = ceil((log_high - log_low) / s.log_gamma) + 1

      assert map_size(s.positive_bins) <= bound,
             "positive_bins grew to #{map_size(s.positive_bins)}, bound #{bound}"

      assert DDSketch.total_count(s) == 100_000
    end

    test "saturating a range and inserting more does not grow the bin set" do
      :rand.seed(:exsss, {7, 8, 9})

      log_low = :math.log(@range_low)
      log_high = :math.log(@range_high)

      sample = fn ->
        :math.exp(log_low + :rand.uniform() * (log_high - log_low))
      end

      # Saturate the range
      saturated =
        Enum.reduce(1..100_000, sketch(), fn _, acc ->
          DDSketch.insert(acc, sample.())
        end)

      bins_after_saturation = map_size(saturated.positive_bins)

      # Pour another 100k observations from the same distribution.
      after_more =
        Enum.reduce(1..100_000, saturated, fn _, acc ->
          DDSketch.insert(acc, sample.())
        end)

      assert map_size(after_more.positive_bins) == bins_after_saturation,
             "bin count grew from #{bins_after_saturation} to #{map_size(after_more.positive_bins)} after pouring in more values from the same range"

      assert DDSketch.total_count(after_more) == 200_000
    end

    test "1_000_000 observations of the same value populates exactly one bin" do
      s =
        Enum.reduce(1..1_000_000, sketch(), fn _, acc ->
          DDSketch.insert(acc, 42.0)
        end)

      assert map_size(s.positive_bins) == 1
      assert s.zero_count == 0
      assert s.negative_bins == %{}
      assert DDSketch.total_count(s) == 1_000_000
    end

    test "symmetric negative input is bounded the same way" do
      :rand.seed(:exsss, {4, 5, 6})

      log_low = :math.log(@range_low)
      log_high = :math.log(@range_high)

      s =
        Enum.reduce(1..50_000, sketch(), fn _, acc ->
          v = :math.exp(log_low + :rand.uniform() * (log_high - log_low))
          DDSketch.insert(acc, -v)
        end)

      bound = ceil((log_high - log_low) / s.log_gamma) + 1

      assert map_size(s.negative_bins) <= bound
      assert s.positive_bins == %{}
    end
  end

  describe "estimator math" do
    test "the bin estimator stays within α relative error of every value in the bin" do
      s = sketch(relative_accuracy: 0.01)
      # Pick a bin and sweep values across its range.
      idx = 100
      lo = :math.pow(s.gamma, idx - 1)
      hi = :math.pow(s.gamma, idx)

      # Pull the estimator out by inserting one observation at any value in the
      # bin and reading min/max of the resulting single-bin sketch — use the
      # same sketch (same γ) so the estimator math lines up with the bin range.
      mid_value = (lo + hi) / 2.0
      single = s |> DDSketch.insert(mid_value)
      estimator = DDSketch.min(single)

      for sample <- [lo + 1.0e-9, mid_value, hi] do
        rel_err = abs(estimator - sample) / sample

        assert rel_err <= s.relative_accuracy + 1.0e-12,
               "estimator #{estimator} not within α of sample #{sample} (err: #{rel_err})"
      end
    end
  end

  # Helper: assert that `actual` is within `tol` relative error of `expected`.
  defp assert_relative_error(actual, expected, tol) do
    err = abs(actual - expected) / abs(expected)

    assert err <= tol + 1.0e-12,
           "expected #{actual} within #{tol} of #{expected}, got relative error #{err}"
  end
end
