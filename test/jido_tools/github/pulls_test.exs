defmodule Jido.Tools.Github.PullsTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Tools.Github.Pulls

  setup :set_mimic_global
  setup :verify_on_exit!

  @mock_client %{access_token: "test_token"}
  @mock_pull_response %{
    "id" => 999,
    "number" => 42,
    "title" => "Add feature",
    "body" => "Implements feature",
    "state" => "open"
  }

  describe "List" do
    test "lists pull requests successfully" do
      mock_pulls = [@mock_pull_response]

      expect(Tentacat.Pulls, :list, fn client, owner, repo ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        mock_pulls
      end)

      params = %{client: @mock_client, owner: "test-owner", repo: "test-repo"}

      assert {:ok, result} = Pulls.List.run(params, %{})
      assert result.status == "success"
      assert result.data == mock_pulls
      assert result.raw == mock_pulls
    end

    test "uses client from tool context" do
      expect(Tentacat.Pulls, :list, fn client, _owner, _repo ->
        assert client == @mock_client
        []
      end)

      params = %{owner: "test-owner", repo: "test-repo"}
      context = %{tool_context: %{client: @mock_client}}

      assert {:ok, result} = Pulls.List.run(params, context)
      assert result.status == "success"
      assert result.data == []
    end
  end

  describe "Find" do
    test "finds pull request by number successfully" do
      expect(Tentacat.Pulls, :find, fn client, owner, repo, number ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        assert number == 42
        @mock_pull_response
      end)

      params = %{client: @mock_client, owner: "test-owner", repo: "test-repo", number: 42}

      assert {:ok, result} = Pulls.Find.run(params, %{})
      assert result.status == "success"
      assert result.data == @mock_pull_response
      assert result.raw == @mock_pull_response
    end
  end

  describe "Create" do
    test "creates pull request with all parameters" do
      expect(Tentacat.Pulls, :create, fn client, owner, repo, body ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"

        assert body == %{
                 title: "Add feature",
                 body: "Implements feature",
                 head: "feature-branch",
                 base: "main"
               }

        @mock_pull_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        title: "Add feature",
        body: "Implements feature",
        head: "feature-branch",
        base: "main"
      }

      assert {:ok, result} = Pulls.Create.run(params, %{})
      assert result.status == "success"
      assert result.data == @mock_pull_response
    end

    test "creates pull request without optional body" do
      expect(Tentacat.Pulls, :create, fn _client, _owner, _repo, body ->
        assert body == %{title: "Add feature", head: "feature-branch", base: "main"}
        @mock_pull_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        title: "Add feature",
        body: nil,
        head: "feature-branch",
        base: "main"
      }

      assert {:ok, result} = Pulls.Create.run(params, %{})
      assert result.status == "success"
    end
  end

  describe "Update" do
    test "updates pull request with all parameters" do
      updated_pull = %{@mock_pull_response | "title" => "Updated title", "state" => "closed"}

      expect(Tentacat.Pulls, :update, fn client, owner, repo, number, body ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        assert number == 42
        assert body == %{title: "Updated title", body: "Updated body", state: "closed"}
        updated_pull
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        number: 42,
        title: "Updated title",
        body: "Updated body",
        state: "closed"
      }

      assert {:ok, result} = Pulls.Update.run(params, %{})
      assert result.status == "success"
      assert result.data == updated_pull
    end

    test "updates pull request removing nil parameters" do
      expect(Tentacat.Pulls, :update, fn _client, _owner, _repo, _number, body ->
        assert body == %{state: "open"}
        @mock_pull_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        number: 42,
        title: nil,
        body: nil,
        state: "open"
      }

      assert {:ok, result} = Pulls.Update.run(params, %{})
      assert result.status == "success"
    end
  end
end
