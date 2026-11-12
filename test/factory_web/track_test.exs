defmodule FactoryWeb.TrackTest do
  use ExUnit.Case, async: true
  alias Factory.Pipeline.Issue
  alias FactoryWeb.Track

  @now ~U[2026-01-01 01:00:00Z]

  defp transition(state, from, to) do
    at = &DateTime.add(~U[2026-01-01 00:00:00Z], &1)
    %{state: state, entered_at: at.(from), left_at: to && at.(to)}
  end

  defp statuses(issue, transitions \\ []) do
    issue |> Track.steps(transitions, [], @now) |> Enum.map(& &1.status)
  end

  test "an agent working marks its step active and the earlier ones done" do
    assert statuses(%Issue{state: "developing"}) == [:done, :done, :active, :pending, :pending]
    assert statuses(%Issue{state: "queued"}) == List.duplicate(:pending, 5)
  end

  test "waiting on a person marks the step it blocks" do
    assert statuses(%Issue{state: "awaiting_answers"}) ==
             [:waiting, :pending, :pending, :pending, :pending]

    assert statuses(%Issue{state: "awaiting_plan_approval"}) ==
             [:done, :waiting, :pending, :pending, :pending]

    assert statuses(%Issue{state: "ready_to_merge"}) == [:done, :done, :done, :done, :waiting]
  end

  test "a held or failed issue shows on the step it will resume" do
    assert statuses(%Issue{state: "needs_human", resume_state: "developing"}) ==
             [:done, :done, :waiting, :pending, :pending]

    assert statuses(%Issue{state: "failed", resume_state: "pr_review"}) ==
             [:done, :done, :done, :failed, :pending]
  end

  test "finished and stopped issues" do
    assert statuses(%Issue{state: "done"}) == List.duplicate(:done, 5)

    assert statuses(%Issue{state: "cancelled"}, [
             transition("planning", 0, 60),
             transition("plan_review", 60, 90),
             transition("cancelled", 90, nil)
           ]) == [:stopped, :stopped, :pending, :pending, :pending]
  end

  test "each step carries its time and its last run" do
    transitions = [
      transition("planning", 0, 60),
      transition("plan_review", 60, 90),
      transition("planning", 90, 120),
      transition("ready_to_merge", 120, 150)
    ]

    runs = [
      %{stage: "planning", model: "claude-opus-5-5"},
      %{stage: "planning", model: "claude-sonnet-5-5"}
    ]

    assert [plan, review, develop, _pr_review, merge] =
             Track.steps(%Issue{state: "ready_to_merge"}, transitions, runs, @now)

    assert {plan.seconds, plan.run.model} == {90, "claude-sonnet-5-5"}
    assert {review.seconds, review.run} == {30, nil}
    assert develop.seconds == nil
    assert merge.seconds == 30
  end
end
