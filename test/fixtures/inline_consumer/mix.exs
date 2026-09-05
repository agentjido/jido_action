defmodule InlineConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :inline_consumer,
      version: "0.1.0",
      deps: [],
      releases: [inline_consumer: [include_erts: false]]
    ]
  end

  def application, do: [extra_applications: [:jido_action]]
end
