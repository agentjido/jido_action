defmodule JidoTest.FlowRefTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow.Ref

  test "validates supported value references" do
    assert :ok = Ref.validate({:input, :order})
    assert :ok = Ref.validate({:result, :load_order})
    assert :ok = Ref.validate({:result, :load_order, [:items, 0]})
    assert :ok = Ref.validate({:value, %{raw: true}})
  end

  test "rejects unsupported value references" do
    assert {:error, "must be a value reference"} = Ref.validate({:element, :item})
    assert {:error, "path must be a non-empty list"} = Ref.validate({:result, :items, []})

    assert {:error, "path must contain only atoms or non-negative integers"} =
             Ref.validate({:result, :items, ["bad"]})
  end

  test "normalizes source shorthands" do
    assert {:ok, nil} = Ref.normalize_source(nil)
    assert {:ok, {:result, :items}} = Ref.normalize_source(:items)
    assert {:ok, {:input, :order}} = Ref.normalize_source({:input, :order})

    assert {:error, "must be a value reference"} = Ref.normalize_source({:element, :item})
  end

  test "normalizes over shorthands" do
    assert {:ok, nil} = Ref.normalize_over(nil)
    assert {:ok, :items} = Ref.normalize_over(:items)

    assert {:ok, {:items, [from: :load_order, path: [:items]]}} =
             Ref.normalize_over({:items, from: :load_order, path: [:items]})

    assert {:error, "over supports only :from and :path"} =
             Ref.normalize_over({:items, from: :load_order, path: [:items], bad: true})

    assert {:error, "over option :from can only be declared once"} =
             Ref.normalize_over({:items, from: :load_order, from: :other, path: [:items]})
  end

  test "derives dependencies from refs and over refs" do
    assert Ref.dependency({:result, :load_order}) == :load_order
    assert Ref.dependency({:result, :load_order, [:items]}) == :load_order
    assert Ref.dependency({:input, :order}) == nil

    assert Ref.over_dependency(:items) == :items
    assert Ref.over_dependency({:items, from: :load_order, path: [:items]}) == :items

    assert Ref.dependencies(%{
             order: {:input, :order},
             items: {:result, :load_order, [:items]},
             profile: {:result, :load_profile}
           }) == [:load_order, :load_profile]
  end
end
