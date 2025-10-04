defmodule IghEthercat do
  alias IghEthercat.{Master, Slave}

  def test do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)
    Slave.set_driver(slave2, IghEthercat.Slave.Example)

    Slave.configure(slave2, domain: :default_domain)

    Slave.watch_value(slave2, self(), :input1)
    Slave.watch_value(slave2, self(), :input9)

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
