defmodule Factory.Projects do
  @moduledoc "Configuration of the repositories the factory works on."
  import Ecto.Query
  alias Factory.Projects.Project
  alias Factory.Repo

  def list_projects, do: Repo.all(from p in Project, order_by: p.repo)
  def list_enabled, do: Repo.all(from p in Project, where: p.enabled, order_by: p.repo)
  def get_project!(id), do: Repo.get!(Project, id)

  def change_project(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)
  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()

  def update_project(%Project{} = project, attrs),
    do: project |> Project.changeset(attrs) |> Repo.update()

  def delete_project(%Project{} = project), do: Repo.delete(project)
end
