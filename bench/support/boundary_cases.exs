defmodule JidoActionBench.Record do
  @moduledoc false
  defstruct [:value]
end

defmodule JidoActionBench.BoundaryCases do
  @moduledoc false
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Codec, Expression, Identity, Ref, Step}
  alias JidoActionBench.{ComponentCases, Echo, Fixtures, Record, SmallResult}

  def workloads do
    expression_cases() ++
      schema_cases() ++ codec_cases() ++ retention_cases() ++ [identity_case()]
  end

  defp expression_cases do
    data = %{
      list: Enum.to_list(1..2_000),
      map: Map.new(1..1_000, &{&1, &1}),
      nested: List.duplicate(%{a: [1, 2, 3], b: %{c: 7}}, 200)
    }

    walks =
      for {shape, value} <- data do
        [
          simple("expr/validate/#{shape}", fn -> Expr.validate(value) end, :ok),
          simple(
            "expr/equal/#{shape}",
            fn ->
              Expr.evaluate(Expr.new!(:eq, [Ref.input(:value), Ref.input(:value)]),
                resolve: fn _ -> {:ok, value} end,
                max_nodes: 100_000
              )
            end,
            {:ok, true}
          ),
          simple(
            "expression/validate/#{shape}",
            fn -> Expression.validate(%{value: value}) end,
            :ok
          ),
          simple(
            "expression/normalize/#{shape}",
            fn -> Expression.normalize(%{value: value}) end,
            {:ok, %{value: value}}
          )
        ]
      end
      |> List.flatten()

    membership =
      for match <- [:first, :last, :miss] do
        operand = %{values: Enum.to_list(1..32)}
        other = %{values: Enum.to_list(2..33)}
        candidates = List.duplicate(other, 31)

        candidates =
          case match do
            :first -> [operand | candidates]
            :last -> candidates ++ [operand]
            :miss -> [other | candidates]
          end

        expression = Expr.new!(:in, [operand, candidates])
        simple("expr/member/#{match}", fn -> Expr.evaluate(expression) end, {:ok, match != :miss})
      end

    invalid = %{items: [1, %{value: [2, fn -> :invalid end]}]}
    expected_error = validation_error(Expression.validate(invalid))

    walks ++
      membership ++
      [
        simple(
          "expression/invalid/nested",
          fn -> validation_error(Expression.validate(invalid)) end,
          expected_error
        )
      ]
  end

  defp validation_error({:error, %{__struct__: type, message: message, details: details}}),
    do: %{type: type, message: message, details: details}

  defp schema_cases do
    for kind <- [:object, :struct], coerce <- [false, true], count <- [0, 200] do
      schema =
        if kind == :object,
          do: Zoi.object(%{value: Zoi.integer()}, coerce: coerce),
          else: Zoi.struct(Record, %{value: Zoi.integer()}, coerce: coerce)

      extra =
        Map.new(
          for index <- List.duplicate(:unused, count) |> Enum.with_index(),
              do: {"unused#{elem(index, 1)}", elem(index, 1)}
        )

      input =
        if kind == :struct and not coerce,
          do: Map.merge(%Record{value: 7}, extra),
          else: Map.put(extra, :value, 7)

      expected = {:ok, Map.put(extra, :value, 7)}

      simple(
        "schema/#{kind}/#{coerce}/#{count}",
        fn -> Jido.Action.Validation.open_validate(schema, input, %{}) end,
        expected
      )
    end
  end

  defp codec_cases do
    for count <- [16, 2_000] do
      params = %{"values" => Map.new(1..count, &{"k#{&1}", &1})}

      flow =
        Flow.new!(
          name: "codec_benchmark",
          components: [Step.new!(name: "echo", action: Echo, params: params)],
          output: Ref.result("echo")
        )

      {:ok, document, registry} = Codec.encode(flow)

      [
        simple(
          "codec/registry/#{count}",
          fn -> Flow.Registry.from_flow(flow) end,
          {:ok, registry}
        ),
        simple(
          "codec/encode_explicit/#{count}",
          fn -> Codec.encode(flow, registry) end,
          {:ok, document}
        ),
        simple(
          "codec/encode_convenience/#{count}",
          fn -> Codec.encode(flow) end,
          {:ok, document, registry}
        ),
        simple("codec/decode/#{count}", fn -> Codec.decode(document, registry) end, {:ok, flow})
      ]
    end
    |> List.flatten()
  end

  defp retention_cases do
    leaf = Enum.to_list(1..500)
    parent = :binary.copy(<<42>>, 1_048_576)

    data = [
      {:small, 42},
      {:list, Enum.to_list(1..5_000)},
      {:shared, List.duplicate(leaf, 16)},
      {:binary, parent},
      {:slice, binary_part(parent, 100, 512)}
    ]

    flow =
      Flow.new!(
        name: "context_retention",
        components: [
          Step.new!(
            name: "small",
            action: SmallResult,
            params: %{value: Ref.input(:value), fail: false}
          )
        ],
        output: Ref.result("small")
      )

    for {kind, payload} <- data, location <- [:input, :context] do
      %{
        id: "payload/#{location}/#{kind}",
        setup: fn context ->
          context = if location == :context, do: Map.put(context, :unused, payload), else: context
          input = %{value: if(location == :input, do: payload, else: 42)}

          {:ok, execution} =
            Exec.start(flow, input, context, task_supervisor: JidoActionBench.TaskSupervisor)

          Fixtures.barrier(context)
          execution
        end,
        run: &Exec.continue/1,
        check: fn {:ok, finished} ->
          ComponentCases.expect!(Exec.result(finished), {:ok, %{value: 42}})
        end,
        retained: fn paused, {:ok, finished} ->
          %{paused_execution: paused, finished_execution: finished}
        end
      }
    end
  end

  defp identity_case do
    digest = :crypto.hash(:sha256, "benchmark") |> Base.encode16(case: :lower)
    # The independent formatter fixes the expected UUID bytes across candidates.
    expected =
      for index <- 0..255 do
        <<a::32, b::16, c::16, d::16, e::48, _::binary>> =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({:jido_flow_item_identity, 1, digest, "node", index}, [
              :deterministic
            ])
          )

        :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
          a,
          b,
          Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x8000),
          Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
          e
        ])
        |> IO.iodata_to_binary()
      end

    simple(
      "identity/items/256",
      fn -> Enum.map(0..255, &Identity.item_uuid(digest, "node", &1)) end,
      expected
    )
  end

  def simple(id, run, expected) do
    %{
      id: id,
      setup: fn _ -> nil end,
      run: fn _ -> run.() end,
      check: &ComponentCases.expect!(&1, expected),
      retained: fn _, result -> %{result: result} end
    }
  end
end
