# Your Second Action

This example shows defaults, output validation, and an explicit side effect boundary.

```elixir
defmodule MyApp.Actions.RegisterUser do
  use Jido.Action,
    name: "register_user",
    description: "Registers a user record",
    schema:
      Zoi.object(%{
        email:
          Zoi.string()
          |> Zoi.trim()
          |> Zoi.to_downcase()
          |> Zoi.regex(Zoi.Regexes.email()),
        display_name:
          Zoi.string()
          |> Zoi.trim()
          |> Zoi.min(1),
        send_welcome?: Zoi.boolean() |> Zoi.default(true)
      }),
    output_schema:
      Zoi.object(%{
        id: Zoi.string(),
        email: Zoi.string(),
        welcome_sent?: Zoi.boolean()
      })

  @impl true
  def run(params, context) do
    repo = Map.fetch!(context, :repo)
    mailer = Map.fetch!(context, :mailer)

    with {:ok, user} <- repo.insert_user(params) do
      welcome_sent? =
        if params.send_welcome? do
          :ok = mailer.deliver_welcome(user.email)
          true
        else
          false
        end

      {:ok, %{id: user.id, email: user.email, welcome_sent?: welcome_sent?}}
    end
  end
end
```

Run it directly:

```elixir
{:ok, params} =
  MyApp.Actions.RegisterUser.validate_params(%{email: "ADA@example.com", display_name: "Ada"})

{:ok, result} =
  MyApp.Actions.RegisterUser.run(params, %{repo: MyApp.Repo, mailer: MyApp.Mailer})
```

Put retry and timeout behavior in the caller or runtime layer that invokes the action.
