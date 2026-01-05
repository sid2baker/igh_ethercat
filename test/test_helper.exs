Node.start(:"master@127.0.0.1")
Node.set_cookie(:ethercat_cookie)
{:ok, peer} = Support.FakeMaster.start_link(:fake_master)
Application.put_env(:ethercat, :fake_master, peer)

ExUnit.start()

ExUnit.after_suite(fn _results ->
  Support.FakeMaster.stop(peer)
end)
