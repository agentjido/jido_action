defmodule Jido.Tools.ReqTool do
  @moduledoc """
  A behavior and macro for creating HTTP request tools using the Req library.

  Provides a standardized way to create actions that make HTTP requests with
  configurable URL, method, headers, and JSON parsing options.
  """

  alias Jido.Action.Error

  @req_config_schema NimbleOptions.new!(
                       url: [type: :string, required: true],
                       method: [type: {:in, [:get, :post, :put, :delete]}, required: true],
                       headers: [
                         type: {:map, :string, :string},
                         default: %{},
                         doc: "HTTP headers to include in the request"
                       ],
                       json: [
                         type: :boolean,
                         default: true,
                         doc: "Whether to parse the response as JSON"
                       ]
                     )

  @doc """
  Callback for transforming the HTTP response result.

  Takes a map with request and response data and returns a transformed result.
  """
  @callback transform_result(map()) :: {:ok, map()} | {:error, any()}

  # Make transform_result optional
  @optional_callbacks [transform_result: 1]

  @doc """
  Macro for setting up a module as a ReqTool with HTTP request capabilities.
  """
  defmacro __using__(opts) do
    escaped_schema = Macro.escape(@req_config_schema)

    quote location: :keep do
      # Separate ReqTool-specific options from base Action options
      req_keys = [:url, :method, :headers, :json]
      req_opts = Keyword.take(unquote(opts), req_keys)
      action_opts = Keyword.drop(unquote(opts), req_keys)

      # Validate ReqTool-specific options
      case NimbleOptions.validate(req_opts, unquote(escaped_schema)) do
        {:ok, validated_req_opts} ->
          # Store validated req opts for later use
          @req_opts validated_req_opts

          # Pass the remaining options to the base Action
          use Jido.Action, action_opts

          # Implement the behavior
          @behaviour Jido.Tools.ReqTool

          # Implement the run function that uses req options
          @impl Jido.Action
          def run(params, context) do
            # Make the actual HTTP request using Req
            req_result = make_request(params, context)

            case req_result do
              {:ok, response} ->
                # Create a standardized result structure
                result = %{
                  request: %{
                    url: @req_opts[:url],
                    method: @req_opts[:method],
                    params: params
                  },
                  response: %{
                    status: response.status,
                    body: response.body,
                    headers: response.headers
                  }
                }

                # Call transform_result, which will either use our default implementation
                # or the user's custom implementation
                transform_result(result)

              {:error, reason} ->
                {:error, reason}
            end
          end

          # Helper function to make the actual HTTP request
          defp make_request(params, _context) do
            # Build the request based on the method
            method = @req_opts[:method]
            url = @req_opts[:url]
            headers = @req_opts[:headers]
            json = @req_opts[:json]

            # Ensure Req is available
            if Code.ensure_loaded?(Req) do
              try do
                # Build options for Req
                req_options = [
                  method: method,
                  url: url,
                  headers: headers
                ]

                # Add JSON decoding if enabled
                req_options =
                  if json, do: Keyword.put(req_options, :decode_json, json), else: req_options

                # Add body for POST/PUT requests if params are provided
                req_options =
                  case method do
                    m when m in [:post, :put] ->
                      Keyword.put(req_options, :json, params)

                    _ ->
                      Keyword.put(req_options, :params, params)
                  end

                # Execute the request
                response = Req.request!(req_options)
                {:ok, response}
              rescue
                e -> {:error, %{type: :http_error, message: Exception.message(e)}}
              end
            else
              {:error,
               %{
                 type: :dependency_error,
                 message:
                   "Req library is required for ReqTool. Add {:req, \"~> 0.3.0\"} to your dependencies."
               }}
            end
          end

          # Default implementation for transform_result
          @impl Jido.Tools.ReqTool
          def transform_result(result) do
            {:ok, result}
          end

          # Allow transform_result to be overridden
          defoverridable transform_result: 1

        {:error, error} ->
          message = Error.format_nimble_config_error(error, "ReqTool", __MODULE__)
          raise CompileError, description: message, file: __ENV__.file, line: __ENV__.line
      end
    end
  end
end
