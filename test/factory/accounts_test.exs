defmodule Factory.AccountsTest do
  use Factory.DataCase, async: true

  import Factory.AccountsFixtures
  alias Factory.Accounts
  alias Factory.Accounts.{Scope, User}

  test "a user needs first name, last name, email, a known role and a long enough password" do
    assert {:error, changeset} = Accounts.create_user(%{role: "owner", password: "short"})

    assert %{
             first_name: ["can't be blank"],
             last_name: ["can't be blank"],
             email: ["can't be blank"],
             role: ["is invalid"],
             password: ["should be at least 12 character(s)"]
           } = errors_on(changeset)

    user = user_fixture(email: " Ana@Example.COM ", role: "operator")
    assert user.email == "ana@example.com"
    assert User.full_name(user) == "Ana Pérez"
    refute user.hashed_password == valid_password()

    assert {:error, changeset} =
             Accounts.create_user(%{
               email: "ana@example.com",
               first_name: "A",
               last_name: "B",
               role: "viewer",
               password: valid_password()
             })

    assert %{email: ["has already been taken"]} = errors_on(changeset)
  end

  test "signing in needs the right password and an active account" do
    user = user_fixture(email: "ana@example.com")

    assert Accounts.authenticate("ANA@example.com", valid_password()).id == user.id
    refute Accounts.authenticate("ana@example.com", "not the password")
    refute Accounts.authenticate("nobody@example.com", valid_password())

    user_fixture()
    {:ok, _} = Accounts.update_user(user, %{active: false})
    refute Accounts.authenticate("ana@example.com", valid_password())
  end

  test "changing role, status or password ends the person's sessions; a rename does not" do
    user_fixture()
    user = user_fixture(role: "operator")
    token = Accounts.create_session(user)
    assert Accounts.get_user_by_session(token).id == user.id

    assert {:ok, {user, []}} = Accounts.update_user(user, %{first_name: "Anita"})
    assert Accounts.get_user_by_session(token)

    assert {:ok, {user, [^token]}} = Accounts.update_user(user, %{role: "viewer"})
    refute Accounts.get_user_by_session(token)

    token = Accounts.create_session(user)

    assert {:ok, {_user, [^token]}} =
             Accounts.update_user(user, %{password: "a brand new password"})

    assert Accounts.authenticate(user.email, "a brand new password")
  end

  test "the last active administrator cannot be demoted or deactivated" do
    admin = user_fixture()

    assert {:error, changeset} = Accounts.update_user(admin, %{role: "operator"})
    assert %{role: ["this is the only active administrator" <> _]} = errors_on(changeset)
    assert {:error, _} = Accounts.update_user(admin, %{active: false})
    assert Accounts.get_user!(admin.id).role == "admin"

    user_fixture()
    assert {:ok, _} = Accounts.update_user(admin, %{role: "operator"})
  end

  test "the first administrator can only be created while there are no users" do
    attrs = %{
      "email" => "first@example.com",
      "first_name" => "First",
      "last_name" => "Admin",
      "password" => valid_password(),
      "role" => "viewer"
    }

    assert {:ok, %User{role: "admin"}} = Accounts.create_first_admin(attrs)

    assert {:error, :already_set_up} =
             Accounts.create_first_admin(%{attrs | "email" => "second@example.com"})
  end

  test "a person changes their own password only with the current one" do
    user = user_fixture()

    new = %{
      "password" => "another long password",
      "password_confirmation" => "another long password"
    }

    assert {:error, changeset} = Accounts.update_password(user, "wrong", new)
    assert %{current_password: ["is not correct"]} = errors_on(changeset)

    assert {:error, changeset} =
             Accounts.update_password(user, valid_password(), %{
               new
               | "password_confirmation" => "x"
             })

    assert %{password_confirmation: ["does not match the new password"]} = errors_on(changeset)

    assert {:ok, _} = Accounts.update_password(user, valid_password(), new)
    assert Accounts.authenticate(user.email, "another long password")
  end

  test "what each role may do" do
    abilities = fn role ->
      scope = Scope.for_user(%User{role: role})
      for ability <- [:view, :operate, :manage], Scope.can?(scope, ability), do: ability
    end

    assert abilities.("admin") == [:view, :operate, :manage]
    assert abilities.("operator") == [:view, :operate]
    assert abilities.("viewer") == [:view]
    refute Scope.can?(nil, :view)
  end
end
