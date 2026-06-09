defmodule Mobius.PersistenceTest do
  use ExUnit.Case, async: true

  alias Mobius.Persistence

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mobius_persistence_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "writes the file and leaves no temp file behind", %{dir: dir} do
    assert :ok = Persistence.write_atomic(dir, "history", "contents")

    assert File.read!(Path.join(dir, "history")) == "contents"
    refute File.exists?(Path.join(dir, "history.tmp"))
  end

  test "a failed write returns the error, removes the temp file and closes the device", %{
    dir: dir
  } do
    test_pid = self()

    write_fun = fn fd, _contents ->
      send(test_pid, {:device, fd})
      {:error, :enospc}
    end

    assert {:error, :enospc} =
             Persistence.write_atomic(dir, "history", "contents", write_fun: write_fun)

    assert_receive {:device, fd}
    refute File.exists?(Path.join(dir, "history.tmp"))
    # The io device must be closed on the error path — the callers are
    # long-lived GenServers, so a leaked device is never reclaimed.
    refute Process.alive?(fd)
  end

  test "a failed sync returns the error, removes the temp file and closes the device", %{
    dir: dir
  } do
    test_pid = self()

    sync_fun = fn fd ->
      send(test_pid, {:device, fd})
      {:error, :enospc}
    end

    assert {:error, :enospc} =
             Persistence.write_atomic(dir, "history", "contents", sync_fun: sync_fun)

    assert_receive {:device, fd}
    refute File.exists?(Path.join(dir, "history.tmp"))
    refute Process.alive?(fd)
  end
end
