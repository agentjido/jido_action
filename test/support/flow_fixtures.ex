defmodule JidoTest.FlowFixtures do
  @moduledoc false

  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  def math_syntax do
    Syntax.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Syntax.step(
      :add_one,
      Add,
      %{
        value: Syntax.input(:value),
        amount: Syntax.value(1)
      }
    )
    |> Syntax.step(
      :double,
      Multiply,
      %{
        value: Syntax.result(:add_one, :value),
        amount: Syntax.value(2)
      }
    )
    |> Syntax.return(Syntax.result(:double, :value))
  end

  def math_builder do
    Builder.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Builder.step(
      :add_one,
      Add,
      %{
        value: Builder.input(:value),
        amount: Builder.value(1)
      }
    )
    |> Builder.step(
      :double,
      Multiply,
      %{
        value: Builder.result(:add_one, :value),
        amount: Builder.value(2)
      }
    )
    |> Builder.return(Builder.result(:double, :value))
  end

  def math_source do
    """
    flow do
      step :add_one, JidoTest.TestActions.Add, %{value: input(:value), amount: value(1)}
      step :double, JidoTest.TestActions.Multiply, %{value: result(:add_one, :value), amount: value(2)}
      return result(:double, :value)
    end
    """
  end

  def binding_syntax do
    Syntax.new(
      name: "binding_flow",
      description: "Adds one and doubles the whole result"
    )
    |> Syntax.step(
      :add_one,
      Add,
      %{
        value: Syntax.input(:value),
        amount: Syntax.value(1)
      },
      bind: :added
    )
    |> Syntax.step(:double, Multiply, Syntax.binding(:added), bind: :doubled)
    |> Syntax.return(Syntax.binding(:doubled))
  end

  def binding_builder do
    Builder.new(
      name: "binding_flow",
      description: "Adds one and doubles the whole result"
    )
    |> Builder.step(
      :add_one,
      Add,
      %{
        value: Builder.input(:value),
        amount: Builder.value(1)
      },
      bind: :added
    )
    |> Builder.step(:double, Multiply, Builder.binding(:added), bind: :doubled)
    |> Builder.return(Builder.binding(:doubled))
  end

  def binding_source do
    """
    flow do
      added = step :add_one, JidoTest.TestActions.Add, with: %{value: input(:value), amount: value(1)}
      doubled = step :double, JidoTest.TestActions.Multiply, with: added
      return doubled
    end
    """
  end

  def projection_syntax do
    Syntax.new(
      name: "projection_flow",
      description: "Projects selected fields into an audit payload"
    )
    |> Syntax.step(
      :load_quote,
      EchoParamsAction,
      Syntax.shape(%{
        quote: %{
          id: Syntax.input(:quote_id),
          pricing: %{total: Syntax.input([:items, 0, :price])}
        },
        tags: [Syntax.input(:tag)]
      }),
      bind: :loaded
    )
    |> Syntax.step(
      :audit_quote,
      EchoParamsAction,
      Syntax.shape(%{
        quote_id: Syntax.select(Syntax.binding(:loaded), [:quote, :id]),
        total: Syntax.select(Syntax.select(Syntax.binding(:loaded), [:quote, :pricing]), :total),
        first_item_id: Syntax.select(Syntax.input(:items), [0, :id]),
        tag: Syntax.select(Syntax.binding(:loaded), [:tags, 0])
      }),
      bind: :audit
    )
    |> Syntax.return(Syntax.select(Syntax.binding(:audit), :total))
  end

  def projection_builder do
    Builder.new(
      name: "projection_flow",
      description: "Projects selected fields into an audit payload"
    )
    |> Builder.step(
      :load_quote,
      EchoParamsAction,
      Builder.shape(%{
        quote: %{
          id: Builder.input(:quote_id),
          pricing: %{total: Builder.input([:items, 0, :price])}
        },
        tags: [Builder.input(:tag)]
      }),
      bind: :loaded
    )
    |> Builder.step(
      :audit_quote,
      EchoParamsAction,
      Builder.shape(%{
        quote_id: Builder.select(Builder.binding(:loaded), [:quote, :id]),
        total:
          Builder.select(Builder.select(Builder.binding(:loaded), [:quote, :pricing]), :total),
        first_item_id: Builder.select(Builder.input(:items), [0, :id]),
        tag: Builder.select(Builder.binding(:loaded), [:tags, 0])
      }),
      bind: :audit
    )
    |> Builder.return(Builder.select(Builder.binding(:audit), :total))
  end

  def projection_source do
    """
    flow do
      loaded =
        step :load_quote, JidoTest.TestActions.EchoParamsAction,
          with: shape(%{
            quote: %{
              id: input(:quote_id),
              pricing: %{total: input([:items, 0, :price])}
            },
            tags: [input(:tag)]
          })

      audit =
        step :audit_quote, JidoTest.TestActions.EchoParamsAction,
          with: shape(%{
            quote_id: select(loaded, [:quote, :id]),
            total: select(select(loaded, [:quote, :pricing]), :total),
            first_item_id: select(input(:items), [0, :id]),
            tag: select(loaded, [:tags, 0])
          })

      return select(audit, :total)
    end
    """
  end

  def math_canonical_map do
    %{
      type: :flow,
      name: "math_flow",
      description: "Adds one and doubles the result",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :add_one,
          action: Add,
          input: %{
            value: %{type: :input, path: [:value]},
            amount: %{type: :value, value: 1}
          },
          deps: []
        },
        %{
          name: :double,
          action: Multiply,
          input: %{
            value: %{type: :result, node: :add_one, path: [:value]},
            amount: %{type: :value, value: 2}
          },
          deps: [:add_one]
        }
      ],
      return: %{type: :result, node: :double, path: [:value]}
    }
  end

  def binding_canonical_map do
    %{
      type: :flow,
      name: "binding_flow",
      description: "Adds one and doubles the whole result",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :add_one,
          action: Add,
          input: %{
            value: %{type: :input, path: [:value]},
            amount: %{type: :value, value: 1}
          },
          deps: []
        },
        %{
          name: :double,
          action: Multiply,
          input: %{type: :result, node: :add_one, path: []},
          deps: [:add_one]
        }
      ],
      return: %{type: :result, node: :double, path: []}
    }
  end

  def projection_canonical_map do
    %{
      type: :flow,
      name: "projection_flow",
      description: "Projects selected fields into an audit payload",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :load_quote,
          action: EchoParamsAction,
          input: %{
            quote: %{
              id: %{type: :input, path: [:quote_id]},
              pricing: %{total: %{type: :input, path: [:items, 0, :price]}}
            },
            tags: [%{type: :input, path: [:tag]}]
          },
          deps: []
        },
        %{
          name: :audit_quote,
          action: EchoParamsAction,
          input: %{
            quote_id: %{type: :result, node: :load_quote, path: [:quote, :id]},
            total: %{type: :result, node: :load_quote, path: [:quote, :pricing, :total]},
            first_item_id: %{type: :input, path: [:items, 0, :id]},
            tag: %{type: :result, node: :load_quote, path: [:tags, 0]}
          },
          deps: [:load_quote]
        }
      ],
      return: %{type: :result, node: :audit_quote, path: [:total]}
    }
  end
end
