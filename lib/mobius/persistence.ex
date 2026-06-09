defmodule Mobius.Persistence do
  @moduledoc false

  # Shared atomic file write used by the persistence save paths
  # (Mobius.Scraper and Mobius.EventsServer).

  @typedoc """
  Test seams for the write and sync steps

  Production callers never pass these; they default to the real
  `IO.binwrite/2` and `:file.sync/1`.
  """
  @type opt() ::
          {:write_fun, (File.io_device(), iodata() -> :ok | {:error, term()})}
          | {:sync_fun, (File.io_device() -> :ok | {:error, term()})}

  @doc """
  Atomically write `contents` to `filename` inside `dir`

  Write-to-tmp + fsync + rename so a power cut mid-write leaves the previous
  file intact instead of a truncated one the next boot cannot load. The
  persistence directory may have been unavailable at boot (or gone away
  since), so re-create it on every attempt.

  On failure the temp file is removed and the error returned; logging is left
  to the caller.
  """
  @spec write_atomic(Path.t(), String.t(), iodata(), [opt()]) :: :ok | {:error, term()}
  def write_atomic(dir, filename, contents, opts \\ []) do
    _ = File.mkdir_p(dir)
    path = Path.join(dir, filename)
    tmp = path <> ".tmp"

    result =
      with {:ok, fd} <- File.open(tmp, [:write, :binary]),
           :ok <- write_sync_close(fd, contents, opts) do
        File.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      error ->
        _ = File.rm(tmp)
        error
    end
  end

  # Close the device on every path — the callers are long-lived GenServers,
  # so a descriptor leaked when the write or sync fails (disk full surfaces
  # exactly there) would never be reclaimed.
  defp write_sync_close(fd, contents, opts) do
    write_fun = Keyword.get(opts, :write_fun, &IO.binwrite/2)
    sync_fun = Keyword.get(opts, :sync_fun, &:file.sync/1)

    result =
      with :ok <- write_fun.(fd, contents) do
        sync_fun.(fd)
      end

    case {result, File.close(fd)} do
      {:ok, close_result} -> close_result
      {error, _close_result} -> error
    end
  end
end
