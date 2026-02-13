defmodule Jido.Tools.Github.Webhooks do
  @moduledoc """
  Tools for interacting with GitHub repository webhooks API.

  Provides actions for listing, creating, and removing repository webhooks.
  """

  defmodule List do
    @moduledoc "Action for listing all webhooks on a GitHub repository."

    use Jido.Action,
      name: "github_webhooks_list",
      description: "List all webhooks from a GitHub repository",
      category: "Github API",
      tags: ["github", "webhooks", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)
      result = Tentacat.Hooks.list(client, params.owner, params.repo)

      {:ok,
       %{
         status: "success",
         data: result,
         raw: result
       }}
    end

    defp get_client(params, context) do
      params[:client] || context[:client] || get_in(context, [:tool_context, :client])
    end
  end

  defmodule Create do
    @moduledoc "Action for creating a webhook on a GitHub repository."

    use Jido.Action,
      name: "github_webhooks_create",
      description: "Create a webhook on a GitHub repository",
      category: "Github API",
      tags: ["github", "webhooks", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        url: [type: :string, doc: "Webhook callback URL"],
        events: [type: {:list, :string}, doc: "Webhook event subscriptions"],
        content_type: [type: :string, doc: "Payload content type (json or form)"],
        secret: [type: :string, doc: "Optional webhook secret"],
        active: [type: :boolean, doc: "Whether webhook is active"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)

      config =
        %{
          "url" => params.url,
          "content_type" => params[:content_type] || "json"
        }
        |> maybe_put("secret", params[:secret])

      body = %{
        "name" => "web",
        "active" => params[:active] != false,
        "events" => params.events,
        "config" => config
      }

      result = Tentacat.Hooks.create(client, params.owner, params.repo, body)

      {:ok,
       %{
         status: "success",
         data: result,
         raw: result
       }}
    end

    defp get_client(params, context) do
      params[:client] || context[:client] || get_in(context, [:tool_context, :client])
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end

  defmodule Remove do
    @moduledoc "Action for removing a webhook from a GitHub repository."

    use Jido.Action,
      name: "github_webhooks_remove",
      description: "Remove a webhook from a GitHub repository",
      category: "Github API",
      tags: ["github", "webhooks", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        hook_id: [type: :integer, doc: "The webhook id to remove"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)
      result = Tentacat.Hooks.remove(client, params.owner, params.repo, params.hook_id)

      {:ok,
       %{
         status: "success",
         data: result,
         raw: result
       }}
    end

    defp get_client(params, context) do
      params[:client] || context[:client] || get_in(context, [:tool_context, :client])
    end
  end
end
