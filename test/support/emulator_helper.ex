defmodule PubsubGrpc.EmulatorHelper do
  @moduledoc """
  Naming and cleanup helpers for tests that run against the Pub/Sub emulator.

  The `track_*` functions must be called from the test process: they register
  an `on_exit` callback that deletes the resource even if the test fails.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @project_id "test-project-id"

  @doc "Project ID used by the emulator tests."
  def project_id, do: @project_id

  @doc "Returns a name that is unique within this VM run, e.g. `topic-42`."
  def unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "Full topic resource path."
  def topic_path(topic_id), do: "projects/#{@project_id}/topics/#{topic_id}"

  @doc "Full subscription resource path."
  def subscription_path(subscription_id),
    do: "projects/#{@project_id}/subscriptions/#{subscription_id}"

  @doc "Full schema resource path."
  def schema_path(schema_id), do: "projects/#{@project_id}/schemas/#{schema_id}"

  @doc "Deletes the topic when the test exits. Returns `topic_id`."
  def track_topic(topic_id) do
    on_exit(fn -> PubsubGrpc.delete_topic(@project_id, topic_id) end)
    topic_id
  end

  @doc "Deletes the subscription when the test exits. Returns `subscription_id`."
  def track_subscription(subscription_id) do
    on_exit(fn -> PubsubGrpc.delete_subscription(@project_id, subscription_id) end)
    subscription_id
  end

  @doc "Deletes the schema when the test exits. Returns `schema_id`."
  def track_schema(schema_id) do
    on_exit(fn -> PubsubGrpc.delete_schema(@project_id, schema_id) end)
    schema_id
  end

  @doc """
  Collects every page of a list call. `list_fun` receives the list options
  (`page_size`, `page_token`) and returns `{:ok, %{^key => items, next_page_token: _}}`.

  Use it instead of asserting membership in the first page: resources leaked by
  aborted runs accumulate in a long-lived emulator.
  """
  def list_all(key, list_fun, page_size \\ 100), do: list_all(key, list_fun, page_size, "", [])

  defp list_all(key, list_fun, page_size, token, acc) do
    {:ok, %{^key => items, next_page_token: next}} =
      list_fun.(page_size: page_size, page_token: token)

    case next do
      "" -> acc ++ items
      next -> list_all(key, list_fun, page_size, next, acc ++ items)
    end
  end

  @doc """
  Setup callback: a tracked unique topic and subscription name, as
  `%{topic_name: _, subscription_name: _}`. Nothing is created.
  """
  def unique_resources(_context \\ %{}) do
    %{
      topic_name: track_topic(unique_name("test-topic")),
      subscription_name: track_subscription(unique_name("test-subscription"))
    }
  end
end
