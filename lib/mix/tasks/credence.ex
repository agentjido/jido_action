defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter across the project's lib/ files"

  @moduledoc """
  Runs `Credence.analyze/2` on every `.ex` file under `lib/` and prints any
  reported issues grouped by file.

  ## Usage

      mix credence            # scans lib/
      mix credence path/...   # scans a specific path (file or dir)
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    roots = if args == [], do: ["lib"], else: args

    files =
      roots
      |> Enum.flat_map(&collect_files/1)
      |> Enum.uniq()
      |> Enum.sort()

    Mix.shell().info("Credence: scanning #{length(files)} file(s)…\n")

    {total_issues, files_with_issues} =
      Enum.reduce(files, {0, 0}, fn path, {issue_acc, file_acc} ->
        code = File.read!(path)

        case Credence.analyze(code, []) do
          %{issues: []} ->
            {issue_acc, file_acc}

          %{issues: issues} ->
            print_file(path, issues)
            {issue_acc + length(issues), file_acc + 1}
        end
      end)

    Mix.shell().info("\nCredence: #{total_issues} issue(s) across #{files_with_issues} file(s).")
  end

  defp collect_files(path) do
    cond do
      File.dir?(path) ->
        Path.wildcard(Path.join(path, "**/*.ex"))

      File.regular?(path) and String.ends_with?(path, ".ex") ->
        [path]

      true ->
        []
    end
  end

  defp print_file(path, issues) do
    Mix.shell().info(IO.ANSI.cyan() <> path <> IO.ANSI.reset())

    Enum.each(issues, fn %Credence.Issue{rule: rule, message: message, meta: meta} ->
      line = Map.get(meta || %{}, :line) || Map.get(meta || %{}, :line_number) || "?"
      Mix.shell().info("  L#{line}  [#{inspect(rule)}] #{message}")
    end)

    Mix.shell().info("")
  end
end
