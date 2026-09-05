# Port closure also closes stdin. Stop the VM if the ExUnit owner exits.
spawn(fn ->
  IO.binread(:stdio, :eof)
  System.halt(125)
end)

# This limit also applies if the test VM stops before it can close the port.
spawn(fn ->
  receive do
  after
    30_000 -> System.halt(124)
  end
end)
