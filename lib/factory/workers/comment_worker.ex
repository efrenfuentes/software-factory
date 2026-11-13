defmodule Factory.Workers.CommentWorker do
  @moduledoc """
  Posts on GitHub a comment written in the panel, once the change it asks for is
  recorded. It is enqueued in the same transaction as that change, so a comment
  is never posted for a request that did not go through.

  Each comment carries a hidden mark with a token of its own: before posting,
  the worker looks for it, so a retry after an answer that got lost does not
  post the comment twice.
  """
  use Oban.Worker, queue: :github, max_attempts: 20
  require Logger
  alias Factory.{GitHub, Pipeline}
  alias Factory.Pipeline.Poller

  @doc "The job that posts `body` on issue or pull request `number` of the issue's repository."
  def new_comment(issue, number, body) do
    token = Ecto.UUID.generate()

    new(%{
      issue_id: issue.id,
      number: number,
      body: body <> "\n\n" <> Poller.panel_mark(token),
      token: token
    })
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"issue_id" => issue_id, "number" => number, "body" => body, "token" => token} = args
    repo = Pipeline.get_issue!(issue_id).project.repo

    result =
      with {:ok, %{comments: comments}} <- GitHub.impl().get_issue(repo, number) do
        if Enum.any?(comments, &String.contains?(&1.body, token)),
          do: :ok,
          else: GitHub.impl().comment(repo, number, body)
      end

    with {:error, reason} <- result do
      if job.attempt >= job.max_attempts do
        Logger.error(
          "Could not post a comment on #{repo}##{number} after #{job.attempt} attempts: " <>
            inspect(reason)
        )
      end

      {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(30 * attempt, 600)
end
