defmodule Jido.Tools.Github.Issues do
  @moduledoc """
  Tools for interacting with GitHub Issues API.

  Provides actions for creating, listing, filtering, finding, and updating GitHub issues.
  """
  defmodule Create do
    @moduledoc "Action for creating new GitHub issues."

    use Jido.Action,
      name: "github_issues_create",
      description: "Create a new issue on GitHub",
      category: "Github API",
      tags: ["github", "issues", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        title: [type: :string, doc: "The title of the issue"],
        body: [type: :string, doc: "The body of the issue"],
        assignee: [type: :string, doc: "The assignee of the issue"],
        milestone: [type: :string, doc: "The milestone of the issue"],
        labels: [type: {:list, :string}, doc: "The labels of the issue"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)

      body =
        %{
          title: params.title,
          body: params.body,
          assignee: params[:assignee],
          milestone: params[:milestone],
          labels: params[:labels]
        }
        |> reject_nil_values()

      result = Tentacat.Issues.create(client, params.owner, params.repo, body)

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

    defp reject_nil_values(map) do
      Enum.reject(map, fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defmodule Filter do
    @moduledoc "Action for filtering GitHub issues by various criteria."

    use Jido.Action,
      name: "github_issues_filter",
      description: "Filter repository issues on GitHub",
      category: "Github API",
      tags: ["github", "issues", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        state: [type: :string, doc: "The state of the issues (open, closed, all)"],
        assignee: [type: :string, doc: "Filter by assignee"],
        creator: [type: :string, doc: "Filter by creator"],
        labels: [type: :string, doc: "Filter by labels (comma-separated)"],
        sort: [type: :string, doc: "Sort by (created, updated, comments)"],
        direction: [type: :string, doc: "Sort direction (asc, desc)"],
        since: [type: :string, doc: "Only show issues updated after this time"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)

      filters =
        %{
          state: params[:state],
          assignee: params[:assignee],
          creator: params[:creator],
          labels: params[:labels],
          sort: params[:sort],
          direction: params[:direction],
          since: params[:since]
        }
        |> reject_empty_filters()

      result = Tentacat.Issues.filter(client, params.owner, params.repo, filters)

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

    defp reject_empty_filters(map) do
      Enum.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end
  end

  defmodule Find do
    @moduledoc "Action for finding a specific GitHub issue by number."

    use Jido.Action,
      name: "github_issues_find",
      description: "Get a specific issue from GitHub",
      category: "Github API",
      tags: ["github", "issues", "api"],
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
      result = Tentacat.Issues.find(client, params.owner, params.repo, params.number)

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

  defmodule List do
    @moduledoc "Action for listing all issues from a GitHub repository."

    use Jido.Action,
      name: "github_issues_list",
      description: "List all issues from a GitHub repository",
      category: "Github API",
      tags: ["github", "issues", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)
      result = Tentacat.Issues.list(client, params.owner, params.repo)

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

  defmodule Update do
    @moduledoc "Action for updating existing GitHub issues."

    use Jido.Action,
      name: "github_issues_update",
      description: "Update an existing issue on GitHub",
      category: "Github API",
      tags: ["github", "issues", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        number: [type: :integer, doc: "The issue number"],
        title: [type: :string, doc: "The new title of the issue"],
        body: [type: :string, doc: "The new body of the issue"],
        assignee: [type: :string, doc: "The new assignee of the issue"],
        state: [type: :string, doc: "The new state of the issue (open, closed)"],
        milestone: [type: :string, doc: "The new milestone of the issue"],
        labels: [type: {:list, :string}, doc: "The new labels of the issue"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = get_client(params, context)

      body =
        %{
          title: params[:title],
          body: params[:body],
          assignee: params[:assignee],
          state: params[:state],
          milestone: params[:milestone],
          labels: params[:labels]
        }
        |> reject_nil_values()

      result =
        Tentacat.Issues.update(client, params.owner, params.repo, params.number, body)

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

    defp reject_nil_values(map) do
      Enum.reject(map, fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end
end
