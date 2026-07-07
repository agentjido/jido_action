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

  def annotated_syntax do
    Syntax.new(
      name: "annotated_flow",
      description: "Annotates a step without changing semantics"
    )
    |> Syntax.step(
      :add_one,
      Add,
      %{
        value: Syntax.input(:value),
        amount: Syntax.value(1)
      },
      bind: :added,
      label: "Add one",
      tags: [:math, "example"],
      note: "Visible only in provenance"
    )
    |> Syntax.return(Syntax.binding(:added))
  end

  def annotated_builder do
    Builder.new(
      name: "annotated_flow",
      description: "Annotates a step without changing semantics"
    )
    |> Builder.step(
      :add_one,
      Add,
      %{
        value: Builder.input(:value),
        amount: Builder.value(1)
      },
      bind: :added,
      label: "Add one",
      tags: [:math, "example"],
      note: "Visible only in provenance"
    )
    |> Builder.return(Builder.binding(:added))
  end

  def annotated_source do
    """
    flow do
      added =
        step :add_one, JidoTest.TestActions.Add,
          with: %{value: input(:value), amount: value(1)},
          label: "Add one",
          tags: [:math, "example"],
          note: "Visible only in provenance"

      return added
    end
    """
  end

  def stored_annotated_source do
    """
    flow do
      added =
        step :add_one, "add",
          with: %{value: input(:value), amount: value(1)},
          label: "Add one",
          tags: [:math, "example"],
          note: "Visible only in provenance"

      return added
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
      %{
        quote: %{
          id: Syntax.input(:quote_id),
          pricing: %{total: Syntax.input([:items, 0, :price])}
        },
        tags: [Syntax.input(:tag)]
      },
      bind: :loaded
    )
    |> Syntax.step(
      :audit_quote,
      EchoParamsAction,
      %{
        quote_id: Syntax.select(Syntax.binding(:loaded), [:quote, :id]),
        total: Syntax.select(Syntax.select(Syntax.binding(:loaded), [:quote, :pricing]), :total),
        first_item_id: Syntax.select(Syntax.input(:items), [0, :id]),
        tag: Syntax.select(Syntax.binding(:loaded), [:tags, 0])
      },
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
      %{
        quote: %{
          id: Builder.input(:quote_id),
          pricing: %{total: Builder.input([:items, 0, :price])}
        },
        tags: [Builder.input(:tag)]
      },
      bind: :loaded
    )
    |> Builder.step(
      :audit_quote,
      EchoParamsAction,
      %{
        quote_id: Builder.select(Builder.binding(:loaded), [:quote, :id]),
        total:
          Builder.select(Builder.select(Builder.binding(:loaded), [:quote, :pricing]), :total),
        first_item_id: Builder.select(Builder.input(:items), [0, :id]),
        tag: Builder.select(Builder.binding(:loaded), [:tags, 0])
      },
      bind: :audit
    )
    |> Builder.return(Builder.select(Builder.binding(:audit), :total))
  end

  def projection_source do
    """
    flow do
      loaded =
        step :load_quote, JidoTest.TestActions.EchoParamsAction,
          with: %{
            quote: %{
              id: input(:quote_id),
              pricing: %{total: input([:items, 0, :price])}
            },
            tags: [input(:tag)]
          }

      audit =
        step :audit_quote, JidoTest.TestActions.EchoParamsAction,
          with: %{
            quote_id: select(loaded, [:quote, :id]),
            total: select(select(loaded, [:quote, :pricing]), :total),
            first_item_id: select(input(:items), [0, :id]),
            tag: select(loaded, [:tags, 0])
          }

      return select(audit, :total)
    end
    """
  end

  def context_syntax do
    Syntax.new(
      name: "context_flow",
      description: "Shapes runtime context into an audit payload"
    )
    |> Syntax.step(
      :audit_request,
      EchoParamsAction,
      %{
        user_id: Syntax.input(:user_id),
        input_trace_id: Syntax.input(:trace_id),
        context_trace_id: Syntax.context(:trace_id),
        tenant_id: Syntax.select(Syntax.context(:tenant), :id)
      },
      bind: :audit
    )
    |> Syntax.return(Syntax.binding(:audit))
  end

  def context_builder do
    Builder.new(
      name: "context_flow",
      description: "Shapes runtime context into an audit payload"
    )
    |> Builder.step(
      :audit_request,
      EchoParamsAction,
      %{
        user_id: Builder.input(:user_id),
        input_trace_id: Builder.input(:trace_id),
        context_trace_id: Builder.context(:trace_id),
        tenant_id: Builder.select(Builder.context(:tenant), :id)
      },
      bind: :audit
    )
    |> Builder.return(Builder.binding(:audit))
  end

  def context_source do
    """
    flow do
      audit =
        step :audit_request, JidoTest.TestActions.EchoParamsAction,
          with: %{
            user_id: input(:user_id),
            input_trace_id: input(:trace_id),
            context_trace_id: context(:trace_id),
            tenant_id: select(context(:tenant), :id)
          }

      return audit
    end
    """
  end

  def explicit_edge_syntax do
    Syntax.new(
      name: "explicit_edge_flow",
      description: "Orders audit after loading without data dependency"
    )
    |> Syntax.step(
      :load_quote,
      EchoParamsAction,
      %{id: Syntax.input(:quote_id)},
      bind: :loaded
    )
    |> Syntax.step(
      :independent,
      EchoParamsAction,
      %{event: "side"}
    )
    |> Syntax.step(
      :audit_quote,
      EchoParamsAction,
      %{event: "quoted"},
      bind: :audit,
      after: [:load_quote, Syntax.binding(:loaded)]
    )
    |> Syntax.return(Syntax.binding(:audit))
  end

  def explicit_edge_builder do
    Builder.new(
      name: "explicit_edge_flow",
      description: "Orders audit after loading without data dependency"
    )
    |> Builder.step(
      :load_quote,
      EchoParamsAction,
      %{id: Builder.input(:quote_id)},
      bind: :loaded
    )
    |> Builder.step(
      :independent,
      EchoParamsAction,
      %{event: "side"}
    )
    |> Builder.step(
      :audit_quote,
      EchoParamsAction,
      %{event: "quoted"},
      bind: :audit,
      after: [:load_quote, Builder.binding(:loaded)]
    )
    |> Builder.return(Builder.binding(:audit))
  end

  def explicit_edge_source do
    """
    flow do
      loaded =
        step :load_quote, JidoTest.TestActions.EchoParamsAction,
          with: %{id: input(:quote_id)}

      step :independent, JidoTest.TestActions.EchoParamsAction,
        with: %{event: "side"}

      audit =
        step :audit_quote, JidoTest.TestActions.EchoParamsAction,
          with: %{event: "quoted"},
          after: [:load_quote, loaded]

      return audit
    end
    """
  end

  def fan_in_syntax do
    Syntax.new(
      name: "fan_in_flow",
      description: "Merges sibling branches through a dependency join"
    )
    |> Syntax.step(
      :load,
      EchoParamsAction,
      %{
        id: Syntax.input(:id),
        base: Syntax.input(:base)
      },
      bind: :loaded
    )
    |> Syntax.step(
      :left,
      EchoParamsAction,
      %{
        side: Syntax.value("left"),
        id: Syntax.select(Syntax.binding(:loaded), :id)
      },
      bind: :left_branch
    )
    |> Syntax.step(
      :right,
      EchoParamsAction,
      %{
        side: Syntax.value("right"),
        base: Syntax.select(Syntax.binding(:loaded), :base)
      },
      bind: :right_branch
    )
    |> Syntax.step(
      :merge,
      EchoParamsAction,
      %{
        left: Syntax.select(Syntax.binding(:left_branch), :side),
        right: Syntax.select(Syntax.binding(:right_branch), :side),
        id: Syntax.select(Syntax.binding(:left_branch), :id)
      },
      bind: :merged
    )
    |> Syntax.return(Syntax.binding(:merged))
  end

  def fan_in_builder do
    Builder.new(
      name: "fan_in_flow",
      description: "Merges sibling branches through a dependency join"
    )
    |> Builder.step(
      :load,
      EchoParamsAction,
      %{
        id: Builder.input(:id),
        base: Builder.input(:base)
      },
      bind: :loaded
    )
    |> Builder.step(
      :left,
      EchoParamsAction,
      %{
        side: Builder.value("left"),
        id: Builder.select(Builder.binding(:loaded), :id)
      },
      bind: :left_branch
    )
    |> Builder.step(
      :right,
      EchoParamsAction,
      %{
        side: Builder.value("right"),
        base: Builder.select(Builder.binding(:loaded), :base)
      },
      bind: :right_branch
    )
    |> Builder.step(
      :merge,
      EchoParamsAction,
      %{
        left: Builder.select(Builder.binding(:left_branch), :side),
        right: Builder.select(Builder.binding(:right_branch), :side),
        id: Builder.select(Builder.binding(:left_branch), :id)
      },
      bind: :merged
    )
    |> Builder.return(Builder.binding(:merged))
  end

  def fan_in_source do
    """
    flow do
      loaded =
        step :load, JidoTest.TestActions.EchoParamsAction,
          with: %{
            id: input(:id),
            base: input(:base)
          }

      left_branch =
        step :left, JidoTest.TestActions.EchoParamsAction,
          with: %{
            side: "left",
            id: select(loaded, :id)
          }

      right_branch =
        step :right, JidoTest.TestActions.EchoParamsAction,
          with: %{
            side: "right",
            base: select(loaded, :base)
          }

      merged =
        step :merge, JidoTest.TestActions.EchoParamsAction,
          with: %{
            left: select(left_branch, :side),
            right: select(right_branch, :side),
            id: select(left_branch, :id)
          }

      return merged
    end
    """
  end

  def branch_group_syntax do
    Syntax.new(
      name: "branch_group_flow",
      description: "Groups static branches without changing runtime semantics"
    )
    |> Syntax.step(
      :load_cart,
      EchoParamsAction,
      %{
        cart_id: Syntax.input(:cart_id),
        items: Syntax.input(:items)
      },
      bind: :cart
    )
    |> Syntax.parallel([
      Syntax.branch(:alpha, [
        syntax_step(
          :price_cart,
          EchoParamsAction,
          %{
            cart_id: Syntax.select(Syntax.binding(:cart), :cart_id),
            total: Syntax.input(:total)
          },
          bind: :priced
        ),
        syntax_step(
          :audit_price,
          EchoParamsAction,
          %{event: "priced"},
          after: Syntax.binding(:priced)
        )
      ]),
      Syntax.branch(:beta, [
        syntax_step(
          :reserve_inventory,
          EchoParamsAction,
          %{
            cart_id: Syntax.select(Syntax.binding(:cart), :cart_id),
            items: Syntax.select(Syntax.binding(:cart), :items)
          },
          bind: :reserved
        )
      ])
    ])
    |> Syntax.step(:post_group_independent, EchoParamsAction, %{event: "side"})
    |> Syntax.step(
      :finalize,
      EchoParamsAction,
      %{
        priced: Syntax.binding(:priced),
        reserved: Syntax.binding(:reserved)
      },
      bind: :final
    )
    |> Syntax.return(Syntax.binding(:final))
  end

  def branch_group_flattened_syntax do
    Syntax.new(
      name: "branch_group_flow",
      description: "Groups static branches without changing runtime semantics"
    )
    |> Syntax.step(
      :load_cart,
      EchoParamsAction,
      %{
        cart_id: Syntax.input(:cart_id),
        items: Syntax.input(:items)
      },
      bind: :cart
    )
    |> Syntax.step(
      :price_cart,
      EchoParamsAction,
      %{
        cart_id: Syntax.select(Syntax.binding(:cart), :cart_id),
        total: Syntax.input(:total)
      },
      bind: :priced
    )
    |> Syntax.step(
      :audit_price,
      EchoParamsAction,
      %{event: "priced"},
      after: Syntax.binding(:priced)
    )
    |> Syntax.step(
      :reserve_inventory,
      EchoParamsAction,
      %{
        cart_id: Syntax.select(Syntax.binding(:cart), :cart_id),
        items: Syntax.select(Syntax.binding(:cart), :items)
      },
      bind: :reserved
    )
    |> Syntax.step(:post_group_independent, EchoParamsAction, %{event: "side"})
    |> Syntax.step(
      :finalize,
      EchoParamsAction,
      %{
        priced: Syntax.binding(:priced),
        reserved: Syntax.binding(:reserved)
      },
      bind: :final
    )
    |> Syntax.return(Syntax.binding(:final))
  end

  def branch_group_builder do
    Builder.new(
      name: "branch_group_flow",
      description: "Groups static branches without changing runtime semantics"
    )
    |> Builder.step(
      :load_cart,
      EchoParamsAction,
      %{
        cart_id: Builder.input(:cart_id),
        items: Builder.input(:items)
      },
      bind: :cart
    )
    |> Builder.parallel([
      Builder.branch(:alpha, [
        syntax_step(
          :price_cart,
          EchoParamsAction,
          %{
            cart_id: Builder.select(Builder.binding(:cart), :cart_id),
            total: Builder.input(:total)
          },
          bind: :priced
        ),
        syntax_step(
          :audit_price,
          EchoParamsAction,
          %{event: "priced"},
          after: Builder.binding(:priced)
        )
      ]),
      Builder.branch(:beta, [
        syntax_step(
          :reserve_inventory,
          EchoParamsAction,
          %{
            cart_id: Builder.select(Builder.binding(:cart), :cart_id),
            items: Builder.select(Builder.binding(:cart), :items)
          },
          bind: :reserved
        )
      ])
    ])
    |> Builder.step(:post_group_independent, EchoParamsAction, %{event: "side"})
    |> Builder.step(
      :finalize,
      EchoParamsAction,
      %{
        priced: Builder.binding(:priced),
        reserved: Builder.binding(:reserved)
      },
      bind: :final
    )
    |> Builder.return(Builder.binding(:final))
  end

  def branch_group_source do
    """
    flow do
      cart =
        step :load_cart, JidoTest.TestActions.EchoParamsAction,
          with: %{
            cart_id: input(:cart_id),
            items: input(:items)
          }

      parallel do
        branch :alpha do
          priced =
            step :price_cart, JidoTest.TestActions.EchoParamsAction,
              with: %{
                cart_id: select(cart, :cart_id),
                total: input(:total)
              }

          step :audit_price, JidoTest.TestActions.EchoParamsAction,
            with: %{event: "priced"},
            after: priced
        end

        branch :beta do
          reserved =
            step :reserve_inventory, JidoTest.TestActions.EchoParamsAction,
              with: %{
                cart_id: select(cart, :cart_id),
                items: select(cart, :items)
              }
        end
      end

      step :post_group_independent, JidoTest.TestActions.EchoParamsAction,
        with: %{event: "side"}

      final =
        step :finalize, JidoTest.TestActions.EchoParamsAction,
          with: %{
            priced: priced,
            reserved: reserved
          }

      return final
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

  def annotated_canonical_map do
    %{
      type: :flow,
      name: "annotated_flow",
      description: "Annotates a step without changing semantics",
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
        }
      ],
      return: %{type: :result, node: :add_one, path: []}
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

  def context_canonical_map do
    %{
      type: :flow,
      name: "context_flow",
      description: "Shapes runtime context into an audit payload",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :audit_request,
          action: EchoParamsAction,
          input: %{
            user_id: %{type: :input, path: [:user_id]},
            input_trace_id: %{type: :input, path: [:trace_id]},
            context_trace_id: %{type: :context, path: [:trace_id]},
            tenant_id: %{type: :context, path: [:tenant, :id]}
          },
          deps: []
        }
      ],
      return: %{type: :result, node: :audit_request, path: []}
    }
  end

  def explicit_edge_canonical_map do
    %{
      type: :flow,
      name: "explicit_edge_flow",
      description: "Orders audit after loading without data dependency",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :independent,
          action: EchoParamsAction,
          input: %{event: %{type: :value, value: "side"}},
          deps: []
        },
        %{
          name: :load_quote,
          action: EchoParamsAction,
          input: %{id: %{type: :input, path: [:quote_id]}},
          deps: []
        },
        %{
          name: :audit_quote,
          action: EchoParamsAction,
          input: %{event: %{type: :value, value: "quoted"}},
          deps: [:load_quote]
        }
      ],
      return: %{type: :result, node: :audit_quote, path: []}
    }
  end

  def fan_in_canonical_map do
    %{
      type: :flow,
      name: "fan_in_flow",
      description: "Merges sibling branches through a dependency join",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :load,
          action: EchoParamsAction,
          input: %{
            id: %{type: :input, path: [:id]},
            base: %{type: :input, path: [:base]}
          },
          deps: []
        },
        %{
          name: :left,
          action: EchoParamsAction,
          input: %{
            side: %{type: :value, value: "left"},
            id: %{type: :result, node: :load, path: [:id]}
          },
          deps: [:load]
        },
        %{
          name: :right,
          action: EchoParamsAction,
          input: %{
            side: %{type: :value, value: "right"},
            base: %{type: :result, node: :load, path: [:base]}
          },
          deps: [:load]
        },
        %{
          name: :merge,
          action: EchoParamsAction,
          input: %{
            left: %{type: :result, node: :left, path: [:side]},
            right: %{type: :result, node: :right, path: [:side]},
            id: %{type: :result, node: :left, path: [:id]}
          },
          deps: [:left, :right]
        }
      ],
      return: %{type: :result, node: :merge, path: []}
    }
  end

  def branch_group_canonical_map do
    %{
      type: :flow,
      name: "branch_group_flow",
      description: "Groups static branches without changing runtime semantics",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :load_cart,
          action: EchoParamsAction,
          input: %{
            cart_id: %{type: :input, path: [:cart_id]},
            items: %{type: :input, path: [:items]}
          },
          deps: []
        },
        %{
          name: :post_group_independent,
          action: EchoParamsAction,
          input: %{event: %{type: :value, value: "side"}},
          deps: []
        },
        %{
          name: :price_cart,
          action: EchoParamsAction,
          input: %{
            cart_id: %{type: :result, node: :load_cart, path: [:cart_id]},
            total: %{type: :input, path: [:total]}
          },
          deps: [:load_cart]
        },
        %{
          name: :reserve_inventory,
          action: EchoParamsAction,
          input: %{
            cart_id: %{type: :result, node: :load_cart, path: [:cart_id]},
            items: %{type: :result, node: :load_cart, path: [:items]}
          },
          deps: [:load_cart]
        },
        %{
          name: :audit_price,
          action: EchoParamsAction,
          input: %{event: %{type: :value, value: "priced"}},
          deps: [:price_cart]
        },
        %{
          name: :finalize,
          action: EchoParamsAction,
          input: %{
            priced: %{type: :result, node: :price_cart, path: []},
            reserved: %{type: :result, node: :reserve_inventory, path: []}
          },
          deps: [:price_cart, :reserve_inventory]
        }
      ],
      return: %{type: :result, node: :finalize, path: []}
    }
  end

  defp syntax_step(name, action, input, opts) do
    Syntax.new(name: "branch")
    |> Syntax.step(name, action, input, opts)
    |> Map.fetch!(:operations)
    |> List.first()
  end
end
