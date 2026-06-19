defmodule Jido.Flow.Script.Renderer do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Script.RefRenderer
  alias Jido.Flow.Switch.Branch

  @spec to_script(Flow.t()) :: String.t()
  def to_script(%Flow{} = flow) do
    flow = Flow.new(Flow.to_map(flow))

    body =
      []
      |> Kernel.++(Enum.map(flow.inputs, &line("input(#{atom(&1)})")))
      |> append_blank_if_needed(
        flow.inputs != [] and (flow.flow != [] or not is_nil(flow.return))
      )
      |> Kernel.++(Enum.flat_map(flow.flow, &entry_to_lines(&1, 1)))
      |> append_blank_if_needed(flow.flow != [] and not is_nil(flow.return))
      |> maybe_append_return(flow.return, 1)

    ["flow #{atom(flow.name)} do", indent_lines(body, 1), "end"]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp maybe_append_return(lines, nil, _level), do: lines

  defp maybe_append_return(lines, return_ref, _level),
    do: lines ++ [line("return(#{ref(return_ref)})")]

  defp append_blank_if_needed(lines, true), do: lines ++ [""]
  defp append_blank_if_needed(lines, false), do: lines

  defp entry_to_lines(%{type: :step} = entry, level) do
    params = Map.get(entry, :params, %{})

    if Enum.any?(params, fn {_key, value} -> reference?(value) end) do
      block =
        params
        |> Enum.map(fn {key, value} -> line("argument(#{atom(key)}, #{ref(value)})") end)
        |> maybe_append_wait_for(Map.get(entry, :after))

      block_entry("step #{atom(entry.name)}, #{module(entry.action)}", block, level)
    else
      opts = []
      opts = if params == %{}, do: opts, else: opts ++ ["params: #{value(params)}"]
      opts = if entry.context == %{}, do: opts, else: opts ++ ["context: #{value(entry.context)}"]
      opts = if entry.after, do: opts ++ ["after: #{value(entry.after)}"], else: opts
      [line("step #{atom(entry.name)}, #{module(entry.action)}#{opts_suffix(opts)}")]
    end
  end

  defp entry_to_lines(%{type: :project} = entry, _level) do
    [
      line(
        "project #{atom(entry.name)}, from: #{atom(entry.from)}, path: #{value(entry.path)}#{mode_suffix(entry.mode)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :map, over: over} = entry, _level) when not is_nil(over) do
    opts = primitive_opts(entry, [])
    [line("map #{atom(entry.name)}, #{callable(entry.mapper)}#{opts_suffix(opts)}")]
  end

  defp entry_to_lines(%{type: :map, source: source} = entry, level) when not is_nil(source) do
    opts = primitive_opts(entry, [])

    block_entry(
      "map #{atom(entry.name)}, #{callable(entry.mapper)}#{opts_suffix(opts)}",
      [line("source(#{ref(source)})")],
      level
    )
  end

  defp entry_to_lines(%{type: :map} = entry, _level) do
    opts = primitive_opts(entry, [])
    [line("map #{atom(entry.name)}, #{callable(entry.mapper)}#{opts_suffix(opts)}")]
  end

  defp entry_to_lines(%{type: :reduce, over: over} = entry, _level) when not is_nil(over) do
    opts = primitive_opts(entry, map_opt(entry))

    [
      line(
        "reduce #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :reduce, source: source} = entry, level) when not is_nil(source) do
    opts = primitive_opts(entry, map_opt(entry))

    block_entry(
      "reduce #{atom(entry.name)}#{opts_suffix(opts)}",
      [
        line("source(#{ref(source)})"),
        line("init(#{value(entry.init)})"),
        line("run(#{callable(entry.reducer)})")
      ],
      level
    )
  end

  defp entry_to_lines(%{type: :reduce} = entry, _level) do
    opts = primitive_opts(entry, map_opt(entry))

    [
      line(
        "reduce #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :accumulate, over: over} = entry, _level) when not is_nil(over) do
    opts = primitive_opts(entry, [])

    [
      line(
        "accumulate #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :accumulate, source: source} = entry, level)
       when not is_nil(source) do
    opts = primitive_opts(entry, [])

    block_entry(
      "accumulate #{atom(entry.name)}#{opts_suffix(opts)}",
      [
        line("source(#{ref(source)})"),
        line("init(#{value(entry.init)})"),
        line("run(#{callable(entry.reducer)})")
      ],
      level
    )
  end

  defp entry_to_lines(%{type: :accumulate} = entry, _level) do
    opts = primitive_opts(entry, [])

    [
      line(
        "accumulate #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :chain} = entry, level) do
    block_entry("chain", Enum.flat_map(entry.flow, &entry_to_lines(&1, level + 1)), level)
  end

  defp entry_to_lines(%{type: :fanout} = entry, level) do
    block_entry(
      "fanout #{atom(entry.from)}",
      Enum.flat_map(entry.flow, &entry_to_lines(&1, level + 1)),
      level
    )
  end

  defp entry_to_lines(%{type: :collect} = entry, level) do
    block =
      Enum.map(entry.arguments, fn {key, value} ->
        line("argument(#{atom(key)}, #{ref(value)})")
      end)

    block_entry("collect #{atom(entry.name)}", block, level)
  end

  defp entry_to_lines(%{type: :debug} = entry, level) do
    block =
      []
      |> maybe_append_source(entry.source)
      |> maybe_append_field(:label, entry.label)
      |> maybe_append_field(:limit, entry.limit)

    block_entry("debug #{atom(entry.name)}", block, level)
  end

  defp entry_to_lines(%{type: :trace} = entry, _level) do
    opts = if entry.source, do: ["source: #{ref(entry.source)}"], else: []
    [line("trace(#{atom(entry.name)}#{opts_suffix(opts)})")]
  end

  defp entry_to_lines(%{type: :switch} = entry, level) do
    if block_switch?(entry) do
      block =
        [line("on(#{ref(entry.on)})"), ""]
        |> Kernel.++(Enum.flat_map(entry.matches, &switch_match_lines(&1, level + 1)))
        |> maybe_append_switch_default(entry.default, level + 1)

      block_entry("switch #{atom(entry.name)}", block, level)
    else
      matches =
        entry.matches
        |> Enum.map(fn match ->
          "{#{atom(match.name)}, {#{callable(match.predicate)}, #{value(match.then)}}}"
        end)
        |> Enum.join(", ")

      opts = [
        "on: #{ref(entry.on)}",
        "matches?: [#{matches}]",
        "default: #{value(entry.default)}",
        "return: #{value(entry.return?)}"
      ]

      [line("switch(#{atom(entry.name)}, #{Enum.join(opts, ", ")})")]
    end
  end

  defp entry_to_lines(entry, _level), do: [line("# unsupported entry #{inspect(entry.type)}")]

  defp block_switch?(entry) do
    Enum.any?(entry.matches, &Branch.flow?/1) or Branch.default?(entry.default)
  end

  defp switch_match_lines(match, level) do
    block =
      Enum.flat_map(match.flow, &entry_to_lines(&1, level + 1))
      |> maybe_append_return(match.return, level + 1)

    block_entry("matches? #{atom(match.name)}, #{callable(match.predicate)}", block, level) ++
      [""]
  end

  defp maybe_append_switch_default(lines, nil, _level), do: lines

  defp maybe_append_switch_default(lines, default, level) do
    if Branch.default?(default) do
      block =
        Enum.flat_map(default.flow, &entry_to_lines(&1, level + 1))
        |> maybe_append_return(default.return, level + 1)

      lines ++ block_entry("default", block, level)
    else
      lines
    end
  end

  defp block_entry(header, block, _level) do
    [line("#{header} do"), indent_lines(block, 1), line("end")]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
  end

  defp indent_lines(lines, level) when is_list(lines) do
    lines
    |> Enum.flat_map(fn
      "" -> [""]
      line -> [String.duplicate("  ", level) <> line]
    end)
  end

  defp line(value), do: value

  defp maybe_append_wait_for(lines, nil), do: lines

  defp maybe_append_wait_for(lines, dependency),
    do: lines ++ [line("wait_for(#{value(dependency)})")]

  defp maybe_append_source(lines, nil), do: lines
  defp maybe_append_source(lines, source), do: lines ++ [line("source(#{ref(source)})")]

  defp maybe_append_field(lines, _field, nil), do: lines
  defp maybe_append_field(lines, field, value), do: lines ++ [line("#{field}(#{value(value)})")]

  defp primitive_opts(entry, extra) do
    opts = []

    opts =
      if entry.after && entry.after != Ref.over_dependency(Map.get(entry, :over)),
        do: opts ++ ["after: #{value(entry.after)}"],
        else: opts

    opts =
      if Map.get(entry, :over),
        do: opts ++ ["over: #{RefRenderer.over(entry.over)}"],
        else: opts

    opts = opts ++ extra
    opts = if entry.inputs, do: opts ++ ["inputs: #{value(entry.inputs)}"], else: opts
    if entry.outputs, do: opts ++ ["outputs: #{value(entry.outputs)}"], else: opts
  end

  defp map_opt(%{map: nil}), do: []
  defp map_opt(%{map: map}), do: ["map: #{atom(map)}"]

  defp opts_suffix([]), do: ""
  defp opts_suffix(opts), do: ", " <> Enum.join(opts, ", ")

  defp mode_suffix(:value), do: ""
  defp mode_suffix(mode), do: ", mode: #{value(mode)}"

  defp ref(value), do: RefRenderer.ref(value)

  defp reference?(value), do: Ref.validate(value) == :ok

  defp callable({module, function}), do: "{#{module(module)}, #{atom(function)}}"
  defp callable({:mfa, module, function}), do: "{:mfa, #{module(module)}, #{atom(function)}}"

  defp value(value), do: inspect(value, charlists: :as_lists)
  defp atom(nil), do: "nil"
  defp atom(value) when is_atom(value), do: inspect(value)
  defp module(value) when is_atom(value), do: inspect(value)
end
