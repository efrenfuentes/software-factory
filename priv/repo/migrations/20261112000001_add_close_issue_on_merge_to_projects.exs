defmodule Factory.Repo.Migrations.AddCloseIssueOnMergeToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :close_issue_on_merge, :boolean, null: false, default: true
    end
  end
end
