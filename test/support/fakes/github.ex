defmodule Factory.Fakes.GitHub do
  @moduledoc "An in-memory GitHub."
  @behaviour Factory.GitHub
  alias Factory.Fakes.State

  def put_issue(number, attrs) do
    issue =
      Map.merge(
        %{title: "Issue #{number}", body: "Body", state: "OPEN", comments: []},
        Map.new(attrs)
      )

    State.update(:issues, &Map.put(&1, number, issue))
  end

  def add_comment(number, author, body, at \\ DateTime.utc_now()) do
    comment = %{author: author, body: body, created_at: DateTime.add(at, 1, :second)}

    State.update(:issues, fn issues ->
      Map.update!(issues, number, &%{&1 | comments: &1.comments ++ [comment]})
    end)
  end

  @doc """
  Adds a submitted review to pull request `number`: its text or, with `path:`
  (and `line:`), a comment on a line. With `state: "PENDING"` it is a draft.
  Like `add_comment/4`, it is dated a second after `at:`.
  """
  def add_review(number, author, body, opts \\ []) do
    at = DateTime.add(Keyword.get(opts, :at, DateTime.utc_now()), 1, :second)
    state = Keyword.get(opts, :state, "COMMENTED")
    submitted_at = if state != "PENDING", do: DateTime.to_iso8601(at)

    State.update(:reviews, fn reviews ->
      pr = Map.get(reviews, number, %{reviews: [], comments: []})
      id = length(pr.reviews) + 1
      path = opts[:path]

      review = %{
        "id" => id,
        "state" => state,
        "body" => if(path, do: "", else: body),
        "user" => %{"login" => author},
        "submitted_at" => submitted_at
      }

      comments =
        if path,
          do: [
            %{
              "pull_request_review_id" => id,
              "body" => body,
              "user" => %{"login" => author},
              "path" => path,
              "line" => opts[:line],
              "original_line" => opts[:line],
              "created_at" => DateTime.to_iso8601(at)
            }
          ],
          else: []

      Map.put(reviews, number, %{
        reviews: pr.reviews ++ [review],
        comments: pr.comments ++ comments
      })
    end)
  end

  @doc """
  Makes `call` (`:get_pr`, `:get_issue`, `:pr_review_comments` or `:comment`) on
  `number` fail until `recover/2`. With `:after`, a comment is posted but the
  answer is lost: it fails after taking effect.
  """
  def fail(call, number, mode \\ :before),
    do: State.update(:failures, &Map.put(&1, {call, number}, mode))

  def recover(call, number), do: State.update(:failures, &Map.delete(&1, {call, number}))

  @doc """
  Runs `fun` once, in the caller, when `call` on `number` next starts. `call`
  can also be `{:set_label, label, present?}`.
  """
  def during(call, number, fun), do: State.update(:hooks, &Map.put(&1, {call, number}, fun))

  defp start(call, number) do
    State.run_hook(:hooks, {call, number})
    Map.get(State.get(:failures), {call, number})
  end

  def posted, do: State.get(:comments) |> Enum.reverse()
  def labels(number), do: Map.get(State.get(:labels), number, MapSet.new())

  @impl true
  def list_issues(_repo, _label), do: {:ok, State.get(:listed)}

  @impl true
  def get_issue(_repo, number) do
    with nil <- start(:get_issue, number),
         %{} = issue <- State.get(:issues)[number] do
      {:ok, issue}
    else
      nil -> {:error, "not found"}
      _failing -> {:error, "unavailable"}
    end
  end

  @impl true
  def comment(_repo, number, body) do
    case start(:comment, number) do
      nil ->
        State.update(:comments, &[{number, body} | &1])
        :ok

      :after ->
        State.update(:comments, &[{number, body} | &1])

        State.update(:issues, fn issues ->
          comment = %{author: "maintainer", body: body, created_at: DateTime.utc_now()}

          if Map.has_key?(issues, number),
            do: Map.update!(issues, number, &%{&1 | comments: &1.comments ++ [comment]}),
            else: issues
        end)

        {:error, "timeout"}

      _before ->
        {:error, "unavailable"}
    end
  end

  @impl true
  def pr_review_comments(_repo, number) do
    case start(:pr_review_comments, number) do
      nil ->
        pr = Map.get(State.get(:reviews), number, %{reviews: [], comments: []})
        {:ok, Factory.GitHub.CLI.review_comments(pr.reviews, pr.comments)}

      _failing ->
        {:error, "unavailable"}
    end
  end

  @impl true
  def create_pr(_repo, attrs) do
    State.update(:prs, &Map.put(&1, 100, Map.put(attrs, :state, "OPEN")))
    put_issue(100, title: attrs.title)
    {:ok, %{number: 100, url: "https://github.com/acme/app/pull/100"}}
  end

  @impl true
  def get_pr(_repo, number) do
    case start(:get_pr, number) do
      nil -> {:ok, %{state: State.get(:prs)[number].state}}
      _failing -> {:error, "unavailable"}
    end
  end

  def set_pr_state(number, state), do: State.update(:prs, &put_in(&1, [number, :state], state))

  @impl true
  def close_issue(_repo, number, comment) do
    State.update(:comments, &[{number, comment} | &1])
    State.update(:issues, &Map.update!(&1, number, fn issue -> %{issue | state: "CLOSED"} end))
    :ok
  end

  @impl true
  def set_label(_repo, number, label, present?) do
    # `during({:set_label, label, present?}, number, fun)` runs `fun` as this starts.
    start({:set_label, label, present?}, number)

    State.update(:labels, fn labels ->
      set = Map.get(labels, number, MapSet.new())

      Map.put(
        labels,
        number,
        if(present?, do: MapSet.put(set, label), else: MapSet.delete(set, label))
      )
    end)
  end

  @impl true
  def current_user, do: {:ok, "maintainer"}
end
