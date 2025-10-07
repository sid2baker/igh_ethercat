defmodule IghEthercat do
  alias IghEthercat.{Master, Domain, Slave}
  alias IghEthercat.Drivers.DefaultDriver

  def test do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)

    Slave.configure(slave2, [])
    Slave.list_pdos(slave2) |> IO.inspect(label: "Options")
    Slave.register_all_pdos(slave2, :default_domain)

    Domain.get_ready(:default_domain)
    Master.activate(master)
    slave2
  end

  def test2 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)
    Slave.set_driver(slave2, IghEthercat.Slave.Example)

    Slave.configure(slave2, domain: :default_domain)

    master
  end

  def get(domain, offset) do
    IghEthercat.Nif.get_domain_value(domain, offset)
  end
end
