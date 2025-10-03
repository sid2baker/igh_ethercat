defmodule IghEthercat do
  alias IghEthercat.{Master, Slave}

  def test do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)
    Slave.set_driver(slave2, IghEthercat.Slave.Example)
    domain = Master.create_domain(master)

    Slave.subscribe_all(slave2, domain)

    Master.activate(master)
    domain
  end

  def get(domain, offset) do
    IghEthercat.Nif.get_domain_value(domain, offset)
  end
end
