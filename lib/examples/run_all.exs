Code.require_file("support.exs", __DIR__)

alias Jido.Examples.Support

Support.ensure!()

Support.example_files()
|> Enum.each(fn file ->
  IO.puts("\n== #{Path.basename(file)}")

  {_output, status} =
    System.cmd("mix", ["run", file],
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    )

  if status != 0 do
    raise "example failed: #{file}"
  end
end)

IO.puts("\nRan #{length(Support.example_files())} examples.")
