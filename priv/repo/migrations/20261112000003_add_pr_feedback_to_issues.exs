defmodule Factory.Repo.Migrations.AddPrFeedbackToIssues do
  use Ecto.Migration

  def up do
    alter table(:issues) do
      # Changes a person asked for on the pull request, until a review approves them.
      add :pr_feedback, :text
      # Those changes once approved: they stay part of the agreed scope.
      add :pr_decisions, :text
      # Comments on the issue or its pull request up to here were already handled.
      add :pr_comments_seen_at, :utc_datetime_usec
    end

    alter table(:transitions) do
      add :hold_reason, :string
    end

    flush()

    # Comments written before this release never open a round.
    execute "UPDATE issues SET pr_comments_seen_at = now()"

    execute """
    UPDATE transitions AS t SET hold_reason = i.hold_reason
    FROM issues AS i
    WHERE t.issue_id = i.id AND t.left_at IS NULL
      AND t.state = 'needs_human' AND i.state = 'needs_human'
    """
  end

  def down do
    alter table(:transitions) do
      remove :hold_reason
    end

    alter table(:issues) do
      remove :pr_comments_seen_at
      remove :pr_decisions
      remove :pr_feedback
    end
  end
end
