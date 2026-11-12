defmodule Factory.Workers.StageWorker do
  @moduledoc "Runs the stage for the state an issue has just entered."
  use Oban.Worker, queue: :agents, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "state" => state}}) do
    issue = Factory.Pipeline.get_issue!(issue_id)
    # The issue may have moved on (stopped, retried) since this job was enqueued.
    if issue.state == state, do: Factory.Pipeline.Stages.run(issue)
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(4)
end
