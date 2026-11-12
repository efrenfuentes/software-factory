defmodule Factory.Workers.PollWorker do
  @moduledoc "Looks at GitHub once a minute."
  use Oban.Worker, queue: :poll, max_attempts: 1, unique: [period: 50]

  @impl Oban.Worker
  def perform(_job), do: Factory.Pipeline.Poller.poll()
end
