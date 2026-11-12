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

  def posted, do: State.get(:comments) |> Enum.reverse()
  def labels(number), do: Map.get(State.get(:labels), number, MapSet.new())

  @impl true
  def list_issues(_repo, _label), do: {:ok, State.get(:listed)}

  @impl true
  def get_issue(_repo, number) do
    case State.get(:issues)[number] do
      nil -> {:error, "not found"}
      issue -> {:ok, issue}
    end
  end

  @impl true
  def comment(_repo, number, body) do
    State.update(:comments, &[{number, body} | &1])
    :ok
  end

  @impl true
  def create_pr(_repo, attrs) do
    State.update(:prs, &Map.put(&1, 100, Map.put(attrs, :state, "OPEN")))
    put_issue(100, title: attrs.title)
    {:ok, %{number: 100, url: "https://github.com/acme/app/pull/100"}}
  end

  @impl true
  def get_pr(_repo, number), do: {:ok, %{state: State.get(:prs)[number].state}}

  def set_pr_state(number, state), do: State.update(:prs, &put_in(&1, [number, :state], state))

  @impl true
  def set_label(_repo, number, label, present?) do
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
