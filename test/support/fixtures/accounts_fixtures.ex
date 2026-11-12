defmodule Factory.AccountsFixtures do
  @moduledoc "Users for tests."

  def valid_password, do: "correct horse battery"

  def user_fixture(attrs \\ []) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user#{n}@example.com",
        first_name: "Ana",
        last_name: "Pérez",
        role: "admin",
        password: valid_password()
      })
      |> Factory.Accounts.create_user()

    user
  end
end
