defmodule Mobius.Exports.CSV do
  @moduledoc false

  @type export_opt() ::
          {:metric_name, binary()}
          | {:tags, [atom()]}
          | {:type, Mobius.metric_type()}
          | Mobius.Exports.csv_export_opt()

  @doc """
  Export metrics to a CSV
  """
  @spec export_metrics([Mobius.metric()], [export_opt()]) :: :ok | {:ok, binary()}
  def export_metrics(metrics, opts \\ []) do
    tag_names = Keyword.fetch!(opts, :tags)
    metric_name = Keyword.fetch!(opts, :metric_name)

    headers = make_csv_headers(tag_names, opts)
    rows = format_metrics_as_csv(metrics, metric_name, tag_names)

    csv_rows = if headers == [], do: rows, else: [headers | rows]

    write_csv(csv_rows, opts)
  end

  defp make_csv_headers(extra_tag_headers, opts) do
    if opts[:headers] == false do
      []
    else
      base_headers = ["timestamp", "name", "type", "value"]

      Enum.reduce(extra_tag_headers, base_headers, fn extra_header, headers ->
        headers ++ [Atom.to_string(extra_header)]
      end)
    end
  end

  defp format_metrics_as_csv(rows, metric_name, tag_names) do
    Enum.map(rows, fn row ->
      tag_values = for tag_name <- tag_names, do: "#{Map.get(row.tags, tag_name, "")}"

      data_row =
        [
          "#{row.timestamp}",
          "#{metric_name}",
          "#{row.type}",
          "#{row.value}"
        ] ++
          tag_values

      data_row
    end)
  end

  defp write_csv(csv_content, opts) do
    case opts[:iodevice] do
      nil ->
        {:ok, Enum.map_join(csv_content, "\n", &format_row/1)}

      device ->
        Enum.each(csv_content, fn row -> IO.write(device, [format_row(row), "\n"]) end)
    end
  end

  defp format_row(row) do
    Enum.map_join(row, ",", &escape_field/1)
  end

  # RFC 4180-style quoting: fields containing the separator, a double quote,
  # or a line break are wrapped in double quotes, with embedded double quotes
  # doubled.
  defp escape_field(field) do
    if String.contains?(field, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end
end
