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
  @spec export_metrics([Mobius.metric()], [export_opt()]) :: :ok | String.t()
  def export_metrics(metrics, opts \\ []) do
    tag_names = Keyword.fetch!(opts, :tags)
    metric_name = Keyword.fetch!(opts, :metric_name)

    headers = make_csv_headers(tag_names, opts)
    rows = format_metrics_as_csv(metrics, metric_name, tag_names)

    write_csv([headers | rows], opts)
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
        {:ok,
         csv_content
         |> Enum.map_join("\n", &Enum.join(&1, ","))
         |> String.trim("\n")}

      device ->
        Enum.each(csv_content, fn row -> IO.write(device, [Enum.intersperse(row, ","), "\n"]) end)
    end
  end
end
