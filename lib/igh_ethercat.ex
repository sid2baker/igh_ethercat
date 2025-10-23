defmodule IghEthercat do
  alias IghEthercat.{Master, Domain, Slave}
  alias IghEthercat.Drivers.DefaultDriver

  def test do
    {:ok, master} = Master.start_link(update_interval: 1000)
    :ok = Master.connect(master)
    {:ok, [koppler, analog, di1, di2, do1, do2]} = Master.sync_slaves(master)
    Slave.configure(di1, [])
    Slave.list_pdos(di1) |> IO.inspect(label: "PDOS")
    Slave.register_all_pdos(di1, :default_domain)
    Domain.get_ready(:default_domain)
    #Master.activate(master)
    master
  end

  def test2 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)

    Slave.configure(slave2, [])
    Slave.list_pdos(slave2) |> IO.inspect(label: "Options")
    Slave.register_all_pdos(slave2, :default_domain)

    Slave.register_pdos(
      slave2,
      [:input1, :input2, :input3, :input4, :input5, :input6, :input7, :input9],
      :default_domain
    )

    Domain.get_ready(:default_domain)
    Master.activate(master)
    slave2
  end

  def test3 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)
    Master.create_domain(master, :domain2, 100)

    Slave.configure(slave2, [])
    Slave.register_pdos(slave2, [:input1], :default_domain)
    Domain.get_ready(:default_domain)
    Slave.register_all_pdos(slave2, :domain2)
    Domain.get_ready(:domain2)
    Master.activate(master)
    master
  end

  def get(domain, offset) do
    IghEthercat.Nif.get_domain_value(domain, offset)
  end
end
