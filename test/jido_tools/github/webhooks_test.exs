defmodule Jido.Tools.Github.WebhooksTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Tools.Github.Webhooks

  setup :set_mimic_global
  setup :verify_on_exit!

  @mock_client %{access_token: "test_token"}
  @mock_webhook_response %{
    "id" => 777,
    "name" => "web",
    "active" => true
  }

  describe "List" do
    test "lists webhooks successfully" do
      hooks = [@mock_webhook_response]

      expect(Tentacat.Hooks, :list, fn client, owner, repo ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        hooks
      end)

      params = %{client: @mock_client, owner: "test-owner", repo: "test-repo"}

      assert {:ok, result} = Webhooks.List.run(params, %{})
      assert result.status == "success"
      assert result.data == hooks
      assert result.raw == hooks
    end
  end

  describe "Create" do
    test "creates webhook with defaults" do
      expect(Tentacat.Hooks, :create, fn client, owner, repo, body ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"

        assert body == %{
                 "name" => "web",
                 "active" => true,
                 "events" => ["push"],
                 "config" => %{
                   "url" => "https://example.com/webhook",
                   "content_type" => "json"
                 }
               }

        @mock_webhook_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        url: "https://example.com/webhook",
        events: ["push"]
      }

      assert {:ok, result} = Webhooks.Create.run(params, %{})
      assert result.status == "success"
      assert result.data == @mock_webhook_response
      assert result.raw == @mock_webhook_response
    end

    test "creates webhook with explicit content type, secret and inactive status" do
      expect(Tentacat.Hooks, :create, fn _client, _owner, _repo, body ->
        assert body == %{
                 "name" => "web",
                 "active" => false,
                 "events" => ["push", "pull_request"],
                 "config" => %{
                   "url" => "https://example.com/webhook",
                   "content_type" => "form",
                   "secret" => "super-secret"
                 }
               }

        @mock_webhook_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        url: "https://example.com/webhook",
        events: ["push", "pull_request"],
        content_type: "form",
        secret: "super-secret",
        active: false
      }

      assert {:ok, result} = Webhooks.Create.run(params, %{})
      assert result.status == "success"
    end
  end

  describe "Remove" do
    test "removes webhook by id" do
      expect(Tentacat.Hooks, :remove, fn client, owner, repo, hook_id ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        assert hook_id == 777
        %{"status" => "deleted"}
      end)

      params = %{client: @mock_client, owner: "test-owner", repo: "test-repo", hook_id: 777}

      assert {:ok, result} = Webhooks.Remove.run(params, %{})
      assert result.status == "success"
      assert result.data == %{"status" => "deleted"}
      assert result.raw == %{"status" => "deleted"}
    end
  end
end
