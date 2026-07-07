defmodule Jido.Action.ApplicationTest do
  use ExUnit.Case, async: true

  test "starts without runtime worker children" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)
    assert [] = Supervisor.which_children(JidoAction.Supervisor)
  end
end
