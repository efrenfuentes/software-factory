defmodule Factory.Stacks do
  @moduledoc """
  Per-stack defaults: how to install dependencies, run the tests and lint.
  A project can override any of the three commands in its configuration.
  """
  alias Factory.Projects.Project

  @type commands :: %{setup: String.t() | nil, test: String.t() | nil, lint: String.t() | nil}

  @spec commands(Project.t(), String.t()) :: commands
  def commands(%Project{} = project, path) do
    defaults = defaults(project.app_type, path)

    %{
      setup: present(project.setup_cmd) || defaults.setup,
      test: present(project.test_cmd) || defaults.test,
      lint: present(project.lint_cmd) || defaults.lint
    }
  end

  @doc "Default commands of a stack. `path` lets them adapt to what the repository uses."
  def defaults("rails", path) do
    %{
      setup: "bundle install",
      test: if(exists?(path, "spec"), do: "bundle exec rspec", else: "bin/rails test"),
      lint: if(exists?(path, ".rubocop.yml"), do: "bundle exec rubocop")
    }
  end

  def defaults("elixir", _path) do
    %{setup: "mix deps.get", test: "mix test", lint: "mix format --check-formatted"}
  end

  def defaults("rust", _path) do
    %{
      setup: "cargo fetch",
      test: "cargo test",
      lint: "cargo fmt --check && cargo clippy --all-targets -- -D warnings"
    }
  end

  def defaults("go", _path) do
    %{setup: "go mod download", test: "go test ./...", lint: "go vet ./..."}
  end

  def defaults("node", path) do
    {install, run} =
      cond do
        exists?(path, "pnpm-lock.yaml") -> {"pnpm install --frozen-lockfile", "pnpm"}
        exists?(path, "yarn.lock") -> {"yarn install --frozen-lockfile", "yarn"}
        true -> {"npm ci", "npm"}
      end

    %{setup: install, test: "#{run} test", lint: "#{run} run lint --if-present"}
  end

  defp exists?(path, name), do: File.exists?(Path.join(path, name))
  defp present(value), do: if(is_binary(value) and String.trim(value) != "", do: value)
end
