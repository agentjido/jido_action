defmodule Jido.Flow.DSL.FormatterTest do
  use ExUnit.Case, async: true

  @package_root Path.expand("../../..", __DIR__)
  @formatter_path Path.join(@package_root, ".formatter.exs")

  @keyword_flow """
  defmodule FeedbackFlow do
    use Jido.Flow, name: "feedback"

    flow do
      step "validate",
        action: Jido.Examples.FeedbackSummarizer.ValidateBatch,
        params: %{comments: input(:comments), summarizer: input(:summarizer)},
        after: ["start"]

      map "clean",
        collection: result("validate", :comments),
        action: Jido.Examples.FeedbackSummarizer.CleanComment,
        params: %{comment: item()}

      reduce "combined",
        collection: result("clean"),
        initial: %{},
        action: Merge,
        params: accumulator()

      dispatch "next", decision: Decide, expander: Expand, params: result("combined")
      output result("next")
    end
  end
  """

  @block_flow """
  flow do
    step "load" do
      action Load
      params %{value: input(:value), context: context()}
      meta %{owner: "example"}
    end

    choice "route" do
      option "match", condition: input(:kind) == :match, action: Match, params: %{}

      option "other" do
        condition input(:kind) == :other
        action Other
        params %{}
      end

      otherwise action: Default, params: %{}
    end

    map "items" do
      collection input(:items)
      action Clean
      params %{item: item(:value)}
      on_error :collect_errors
    end

    iterate "loop" do
      state [], initial: %{count: 0}
      action Increment
      params %{count: state(:count)}
      update %{count: body_result(:count)}
      while state(:count) < 3
      max_iterations 3
    end

    iterate "fixed" do
      state [] do
        initial %{count: 0}
      end

      action Increment
      params state()
      repeat 3
    end

    dispatch "next" do
      decision Decide
      expander Expand
      params result("fixed")
    end

    output result("next")
  end
  """

  test "the project formatter preserves keyword and block declarations without parentheses" do
    {formatter, _opts} =
      Mix.Tasks.Format.formatter_for_file("flow.ex", dot_formatter: @formatter_path)

    for source <- [@keyword_flow, @block_flow] do
      assert formatter.(source) == source
      assert formatter.(formatter.(source)) == source
    end
  end

  @tag :tmp_dir
  test "a consumer imports the same rules from jido_action", %{tmp_dir: tmp_dir} do
    consumer_formatter = Path.join(tmp_dir, ".formatter.exs")
    File.write!(consumer_formatter, "[import_deps: [:jido_action]]\n")

    {formatter, _opts} =
      Mix.Tasks.Format.formatter_for_file("flow.ex",
        dot_formatter: consumer_formatter,
        deps_paths: %{jido_action: @package_root}
      )

    for source <- [@keyword_flow, @block_flow] do
      assert formatter.(source) == source
    end
  end

  test "the Hex package includes the exported formatter configuration" do
    assert ".formatter.exs" in Mix.Project.config()[:package][:files]
  end

  test "reference calls and explicit parentheses stay unchanged" do
    {formatter, _opts} =
      Mix.Tasks.Format.formatter_for_file("flow.ex", dot_formatter: @formatter_path)

    source = "step(1)\nstate(:count)\noutput(result(\"value\"))\nEnum.map(items, fun)\n"
    assert formatter.(source) == source
  end
end
