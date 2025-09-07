defmodule PubsubGrpc.Auth do
  @moduledoc """
  Authentication module for Google Cloud Pub/Sub using Goth library.

  This module handles authentication token retrieval using multiple methods:
  1. Goth library (if available and configured)
  2. gcloud CLI fallback
  3. Default application credentials

  ## Configuration

  To use Goth for authentication, add it to your supervision tree:

      children = [
        {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
        # ... other children
      ]

  Then configure PubsubGrpc to use your Goth instance:

      config :pubsub_grpc, :goth, MyApp.Goth

  ## Usage

  This module is used internally by PubsubGrpc and typically doesn't need
  to be called directly.
  """

  @doc """
  Gets an authentication token for Google Cloud API calls.

  Returns a token string in the format "Bearer <token>" or nil if
  authentication is not available.

  ## Returns
  - `{:ok, "Bearer <token>"}` - Token retrieved successfully
  - `{:error, reason}` - Unable to get token

  ## Examples

      {:ok, token} = PubsubGrpc.Auth.get_token()
      # Returns: {:ok, "Bearer ya29.a0AS3..."}

  """
  def get_token do
    case Application.get_env(:pubsub_grpc, :goth) do
      nil ->
        # Fallback to gcloud CLI or default credentials
        get_token_fallback()

      goth_name ->
        # Use Goth library
        get_token_from_goth(goth_name)
    end
  end

  @doc """
  Gets request options including authentication metadata.

  This function is used internally to add authentication headers
  to GRPC requests.

  ## Returns
  List of options to pass to GRPC stub functions.

  ## Examples

      opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request, opts)

  """
  def request_opts do
    # Skip authentication for emulator environments
    case Application.get_env(:pubsub_grpc, :emulator) do
      nil ->
        # Production - use authentication
        case get_token() do
          {:ok, token} ->
            [metadata: %{"authorization" => token}]

          {:error, _reason} ->
            []
        end

      _emulator_config ->
        # Emulator - no authentication needed
        []
    end
  end

  # Private functions

  defp get_token_from_goth(goth_name) do
    if Code.ensure_loaded?(Goth) do
      case Goth.fetch(goth_name) do
        {:ok, %{token: token, type: type}} ->
          {:ok, "#{type} #{token}"}

        {:error, reason} ->
          # Fallback to CLI if Goth fails
          case get_token_fallback() do
            {:ok, token} -> {:ok, token}
            {:error, _} -> {:error, {:goth_error, reason}}
          end
      end
    else
      # Goth not available, use fallback
      get_token_fallback()
    end
  end

  defp get_token_fallback do
    try do
      # Try gcloud CLI first
      case System.cmd("gcloud", ["auth", "application-default", "print-access-token"],
             stderr_to_stdout: true
           ) do
        {token_output, 0} ->
          token = String.trim(token_output)
          {:ok, "Bearer #{token}"}

        {error_output, _} ->
          {:error, {:gcloud_error, String.trim(error_output)}}
      end
    rescue
      _ -> {:error, :no_auth_available}
    catch
      _ -> {:error, :no_auth_available}
    end
  end
end
