defmodule Jido.Tools.Github.IssueComments do
  @moduledoc """
  Tools for interacting with GitHub Issue Comments API.

  Provides actions for listing and creating comments on GitHub issues.
  """

  defmodule List do
    @moduledoc "Action for listing comments on a GitHub issue."

    use Jido.Action,
      name: "github_issue_comments_list",
      description: "List all comments on an issue",
      category: "Github API",
      tags: ["github", "issues", "comments", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        number: [type: :integer, doc: "The issue number"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)
      result = Tentacat.Issues.Comments.list(client, params.owner, params.repo, params.number)

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
    @moduledoc "Action for creating a comment on a GitHub issue."

    use Jido.Action,
      name: "github_issue_comments_create",
      description: "Create a comment on an issue",
      category: "Github API",
      tags: ["github", "issues", "comments", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        number: [type: :integer, doc: "The issue number"],
        body: [type: :string, doc: "The comment body"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)
      body = %{body: params.body}

      result =
        Tentacat.Issues.Comments.create(client, params.owner, params.repo, params.number, body)

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
