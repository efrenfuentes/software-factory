defmodule Factory.Accounts.User do
  @moduledoc """
  A person who can sign in to the factory. Accounts are created by an
  administrator; nobody registers by themselves.

  Roles, from most to least access:

    * `admin` - everything, including projects and users
    * `operator` - acts on issues (approve, ask for changes, retry, stop) but
      cannot change projects or users
    * `viewer` - reads everything, changes nothing
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @roles ~w(admin operator viewer)

  schema "users" do
    field :email, :string
    field :first_name, :string
    field :last_name, :string
    field :role, :string, default: "viewer"
    field :active, :boolean, default: true
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def full_name(%__MODULE__{first_name: first, last_name: last}), do: "#{first} #{last}"

  def initials(%__MODULE__{first_name: first, last_name: last}),
    do: String.upcase(String.first(first) <> String.first(last))

  @doc """
  For an administrator creating or editing an account. The password is required
  for a new account and optional afterwards (empty keeps the current one).
  """
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :first_name, :last_name, :role, :active, :password])
    |> validate_profile()
    |> validate_inclusion(:role, @roles)
    |> validate_password(required: is_nil(user.id))
  end

  @doc "For a person changing their own password."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match the new password")
    |> validate_password(required: true)
  end

  defp validate_profile(changeset) do
    changeset
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:first_name, &String.trim/1)
    |> update_change(:last_name, &String.trim/1)
    |> validate_required([:email, :first_name, :last_name, :role])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be an email address")
    |> validate_length(:email, max: 160)
    |> validate_length(:first_name, max: 80)
    |> validate_length(:last_name, max: 80)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset, opts) do
    changeset =
      if opts[:required], do: validate_required(changeset, [:password]), else: changeset

    changeset
    # bcrypt only reads the first 72 bytes.
    |> validate_length(:password, min: 12, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      password when is_binary(password) and changeset.valid? ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)

      _ ->
        changeset
    end
  end

  @doc "Checks a password, taking the same time whether or not the account exists."
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0,
      do: Bcrypt.verify_pass(password, hashed)

  def valid_password?(_user, _password) do
    Bcrypt.no_user_verify()
    false
  end
end
