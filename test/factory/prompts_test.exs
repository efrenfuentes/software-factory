defmodule Factory.Agents.PromptsTest do
  use ExUnit.Case, async: true
  alias Factory.Agents.Prompts
  alias Factory.Pipeline.Issue

  @issue %Issue{number: 7, title: "Add export"}
  @context %{review: nil, gate_failure: nil, checks: "- `mix test`"}
  @review %{"summary" => "Not yet", "blocking" => ["Fix X"], "minor" => []}

  test "without a maintainer's feedback the Developer works on the plan as before" do
    prompt = Prompts.developer(@issue, @context)
    assert prompt =~ "Implement every unchecked task"
    assert prompt =~ "Keep the change limited to what\nthe plan asks for."
    refute prompt =~ "<comments>"
  end

  test "a maintainer's feedback is the main task, and wins over the Reviewer" do
    feedback = "[maintainer @maintainer, on the pull request]\nRename the CSV"

    prompt =
      Prompts.developer(@issue, Map.merge(@context, %{review: @review, feedback: feedback}))

    assert prompt =~ "A maintainer asked for changes to the pull request"
    assert prompt =~ "<comments>\n[maintainer @maintainer, on the pull request]\nRename the CSV"
    assert prompt =~ "Fix X"
    assert prompt =~ "the maintainer's feedback wins"
    assert prompt =~ "the plan and the maintainer's decisions ask for"
    refute prompt =~ "Implement every unchecked task"
  end

  test "earlier decisions are part of the agreed scope" do
    prompt =
      Prompts.developer(
        @issue,
        Map.merge(@context, %{feedback: "Add a header", decisions: "Rename the CSV"})
      )

    assert prompt =~ "Add a header"
    assert prompt =~ "Rename the CSV"
    assert prompt =~ "already implemented and part of the\nagreed scope"
  end

  test "the Reviewer checks the feedback and never calls the decisions out of scope" do
    issue = %{@issue | pr_feedback: "Add a header", pr_decisions: "Rename the CSV"}
    prompt = Prompts.pr_reviewer(issue, "main")

    assert prompt =~ "Add a header"
    assert prompt =~ "anything missing is blocking"
    assert prompt =~ "Rename the CSV"

    assert prompt =~
             "part of the agreed scope; never call\nwork that implements them out of scope"

    refute Prompts.pr_reviewer(@issue, "main") =~ "<comments>"
  end
end
