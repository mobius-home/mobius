defmodule Example do

  def simulate_vintage_qmi_connection_event(ifname, connection_status) do
    :telemetry.execute(
      [:vintage_net_qmi, :connection],
      %{},
      %{ifname: ifname, status: connection_status}
    )
  end

  def simulate_vintage_qmi_connection_end_event(ifname, connection_status) do
    duration = :rand.uniform(100) * 10_000

    :telemetry.execute(
      [:vintage_net_qmi, :connection, :end],
      %{duration: duration},
      %{ifname: ifname, status: connection_status}
    )
  end

  def inc(ifname \\ "wwan0") do
    :telemetry.execute(
      [:example, :inc],
      %{duration: 100},
      %{ifname: ifname}
    )
  end
end
