defmodule IghEthercat do
  alias IghEthercat.{Master, Slave}

  def test do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [slave1, slave2]} = Master.sync_slaves(master)
    IO.inspect(Slave.get_pdos(slave2, 0))
    master
  end
end
