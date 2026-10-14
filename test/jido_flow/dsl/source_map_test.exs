defmodule Jido.Flow.DSL.SourceMapTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.DSL.SourceMap

  test "error paths select the closest declaration before component or role hints" do
    component = %{file: "flow.ex", line: 4}
    option = %{file: "flow.ex", line: 5}
    fallback = %{file: "flow.ex", line: 6}

    sources = %{
      [:components, "route"] => component,
      [:components, "route", :options, "selected"] => option,
      [:components, "route", :fallback] => fallback
    }

    assert SourceMap.lookup(sources, %{
             path: [:components, "route", :options, "selected", :call, :params, :nested],
             component: "route",
             field: :fallback
           }) == option

    assert SourceMap.lookup(sources, %{component: "route", field: "selected"}) == option
    assert SourceMap.lookup(sources, %{component: "route", field: :fallback}) == fallback
    assert SourceMap.lookup(sources, %{component: "route", field: "missing"}) == component
    assert SourceMap.lookup(sources, %{component: "route"}) == component
    assert SourceMap.lookup(sources, %{path: [:output]}) == nil
    assert SourceMap.lookup(sources, %{}) == nil
  end
end
