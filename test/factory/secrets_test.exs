defmodule Factory.SecretsTest do
  # Changes the application's configuration (the key, the passthrough).
  use Factory.DataCase, async: false

  alias Factory.{Projects, Secrets}
  alias Factory.Projects.Project
  alias Factory.Secrets.{Bundle, Cipher, ProjectSecret}

  @value "s3cr3t-value"

  setup do
    key = Application.get_env(:factory, :secrets_key)
    passthrough = Application.get_env(:factory, :env_passthrough)

    on_exit(fn ->
      Application.put_env(:factory, :secrets_key, key)

      if passthrough,
        do: Application.put_env(:factory, :env_passthrough, passthrough),
        else: Application.delete_env(:factory, :env_passthrough)
    end)

    {:ok, project} =
      Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "x"})

    user = Factory.AccountsFixtures.user_fixture(first_name: "Ada")

    %{project: project, user: user}
  end

  defp entry(name, value, checks_only \\ false),
    do: %{name: name, value: value, checks_only: checks_only}

  describe "Cipher" do
    test "encrypts and decrypts, bound to its associated data" do
      aad = Cipher.aad(1, "API_KEY")
      assert {:ok, blob} = Cipher.encrypt(@value, aad)
      refute blob =~ @value
      assert <<1, _iv::binary-size(12), _tag::binary-size(16), _::binary>> = blob
      assert Cipher.decrypt(blob, aad) == {:ok, @value}

      assert Cipher.decrypt(blob, Cipher.aad(2, "API_KEY")) == :error
      assert Cipher.decrypt(blob, Cipher.aad(1, "OTHER")) == :error

      <<head::binary-size(30), byte, rest::binary>> = blob
      assert Cipher.decrypt(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>, aad) == :error
      assert Cipher.decrypt("short", aad) == :error
    end

    test "decodes the key" do
      assert {:ok, <<_::binary-size(32)>>} =
               Cipher.decode_key(Base.encode64(:binary.copy("k", 32)))

      assert {:error, _} = Cipher.decode_key("x")
      assert {:error, _} = Cipher.decode_key(Base.encode64(:binary.copy("k", 16)))
      assert Cipher.decode_key(nil) == :missing
    end

    test "check_key!/0 raises for a malformed key, not for a missing one" do
      Application.put_env(:factory, :secrets_key, "x")
      assert_raise ArgumentError, ~r/openssl rand -base64 32/, fn -> Cipher.check_key!() end

      Application.put_env(:factory, :secrets_key, nil)
      assert Cipher.check_key!() == :ok
    end

    test "the fingerprint depends on the key and does not reveal it" do
      a = :binary.copy("a", 32)
      b = :binary.copy("b", 32)
      assert Cipher.fingerprint(a) == Cipher.fingerprint(a)
      refute Cipher.fingerprint(a) == Cipher.fingerprint(b)
      assert String.length(Cipher.fingerprint(a)) == 16
    end
  end

  describe "validation" do
    defp create_errors(attrs) do
      attrs = Map.merge(%{"name" => "API_KEY", "value" => @value}, attrs)
      errors_on(ProjectSecret.create_changeset(%ProjectSecret{}, attrs))
    end

    test "reserved and malformed names are refused" do
      Application.put_env(:factory, :env_passthrough, ["GH_TOKEN"])

      for name <- ~w(PATH path LC_ALL FACTORY_X GH_TOKEN) do
        assert ["is reserved" <> _] = create_errors(%{"name" => name}).name, name
      end

      for name <- ["1ABC", "A-B"] do
        assert ["must start with" <> _] = create_errors(%{"name" => name}).name, name
      end

      assert %{name: [_ | _]} = create_errors(%{"name" => String.duplicate("A", 129)})
      assert create_errors(%{"name" => "DATABASE_URL"}) == %{}
    end

    test "values are at least 8 characters, at most 32 768 bytes, without NUL" do
      assert %{value: ["should be at least 8 character(s)"]} =
               create_errors(%{"value" => "1234567"})

      assert %{value: ["must not contain a NUL byte"]} =
               create_errors(%{"value" => "abcd" <> <<0>> <> "efgh"})

      assert %{value: [_]} = create_errors(%{"value" => String.duplicate("a", 32_769)})
      assert create_errors(%{"value" => String.duplicate("a", 32_768)}) == %{}
      assert %{value: ["can't be blank"]} = create_errors(%{"value" => ""})
    end

    test "values are normalized" do
      changeset =
        ProjectSecret.create_changeset(%ProjectSecret{}, %{
          "name" => "TOKEN",
          "value" => "  tok-12345678\r\n"
        })

      assert Ecto.Changeset.get_change(changeset, :value) == "tok-12345678"

      pem = "-----BEGIN KEY-----\r\nabcdefgh12345678\r\n-----END KEY-----\r\n"

      changeset =
        ProjectSecret.create_changeset(%ProjectSecret{}, %{"name" => "PEM", "value" => pem})

      assert Ecto.Changeset.get_change(changeset, :value) ==
               "-----BEGIN KEY-----\nabcdefgh12345678\n-----END KEY-----\n"
    end
  end

  describe "the panel's operations" do
    test "the value is only stored encrypted, bound to its project and name", %{
      project: project,
      user: user
    } do
      assert {:ok, secret} =
               Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

      assert secret.value == nil
      row = Repo.get!(ProjectSecret, secret.id)
      refute row.encrypted_value =~ @value
      assert row.updated_by_id == user.id
      assert row.key_fingerprint == Secrets.current_fingerprint()

      assert Cipher.decrypt(row.encrypted_value, Cipher.aad(project.id, "API_KEY")) ==
               {:ok, @value}

      assert {:error, changeset} =
               Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

      assert %{name: ["already exists — use Replace"]} = errors_on(changeset)

      {:ok, other} =
        Projects.create_project(%{repo: "acme/other", app_type: "elixir", allowed_users: "x"})

      Repo.update_all(from(s in ProjectSecret, where: s.id == ^secret.id),
        set: [project_id: other.id]
      )

      assert {:error, message} = Secrets.load(other)
      assert message =~ "API_KEY"
      refute message =~ @value

      Repo.update_all(from(s in ProjectSecret, where: s.id == ^secret.id),
        set: [project_id: project.id, name: "RENAMED"]
      )

      assert {:error, message} = Secrets.load(project)
      assert message =~ "RENAMED"
    end

    test "an empty replacement only changes checks_only, the date and the author", %{
      project: project,
      user: user
    } do
      {:ok, secret} =
        Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

      before = Repo.get!(ProjectSecret, secret.id)

      Repo.update_all(from(s in ProjectSecret, where: s.id == ^secret.id),
        set: [updated_at: ~U[2020-01-01 00:00:00Z], updated_by_id: nil]
      )

      listed = Secrets.get_secret!(project, secret.id)

      assert {:ok, _} =
               Secrets.replace_secret(listed, %{"value" => "", "checks_only" => "true"}, user)

      after_replace = Repo.get!(ProjectSecret, secret.id)
      assert after_replace.encrypted_value == before.encrypted_value
      assert after_replace.checks_only
      assert after_replace.updated_by_id == user.id
      assert DateTime.compare(after_replace.updated_at, ~U[2020-01-01 00:00:00Z]) == :gt

      assert {:ok, _} = Secrets.replace_secret(listed, %{"value" => "a-new-value-123"}, user)
      assert {:ok, bundle} = Secrets.load(project)
      assert Secrets.env(bundle, :checks) == [{"API_KEY", "a-new-value-123"}]

      assert {:error, changeset} = Secrets.replace_secret(listed, %{"value" => "short"}, user)
      assert %{value: [_]} = errors_on(changeset)
    end

    test "without a key nothing is added or replaced, and deleting works", %{
      project: project,
      user: user
    } do
      {:ok, secret} =
        Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

      Application.put_env(:factory, :secrets_key, nil)
      refute Secrets.key_available?()
      assert Secrets.current_fingerprint() == nil

      assert {:error, :no_key} =
               Secrets.create_secret(project, %{"name" => "OTHER", "value" => @value}, user)

      listed = Secrets.get_secret!(project, secret.id)
      assert {:error, :no_key} = Secrets.replace_secret(listed, %{"value" => @value}, user)
      assert {:ok, _} = Secrets.delete_secret(listed)
      assert Secrets.list_secrets(project) == []
    end

    test "the list never reads the values", %{project: project, user: user} do
      {:ok, _} = Secrets.create_secret(project, %{"name" => "B_KEY", "value" => @value}, user)
      {:ok, _} = Secrets.create_secret(project, %{"name" => "A_KEY", "value" => @value}, user)

      assert [%{name: "A_KEY", encrypted_value: nil, updated_by: %{first_name: "Ada"}}, b] =
               Secrets.list_secrets(project)

      assert b.encrypted_value == nil
    end

    test "deleting the project deletes its secrets", %{project: project, user: user} do
      {:ok, _} = Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)
      {:ok, _} = Projects.delete_project(project)
      assert Repo.aggregate(ProjectSecret, :count) == 0
    end
  end

  describe "a stage's secrets" do
    test "a project without secrets loads an empty bundle, even without a key", %{
      project: project
    } do
      Application.put_env(:factory, :secrets_key, nil)
      assert {:ok, %Bundle{entries: []} = bundle} = Secrets.load(project)
      refute Secrets.any?(bundle)
    end

    test "secrets without a key, or stored with another key, cannot be loaded", %{
      project: project,
      user: user
    } do
      {:ok, _} = Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

      Application.put_env(:factory, :secrets_key, nil)
      assert {:error, message} = Secrets.load(project)
      assert message =~ "API_KEY"
      assert message =~ "FACTORY_SECRETS_KEY"
      refute message =~ @value

      Application.put_env(:factory, :secrets_key, Base.encode64(:binary.copy("o", 32)))
      assert {:error, message} = Secrets.load(project)
      assert message =~ "API_KEY"
      refute message =~ @value
    end

    test "env/2 gives each process the secrets it may see" do
      Application.put_env(:factory, :env_passthrough, ["PASSED"])

      bundle =
        Bundle.new([
          entry("API_KEY", "value-one-1"),
          entry("CHECK_ONLY", "value-two-2", true),
          entry("PASSED", "value-three-3")
        ])

      assert Secrets.env(bundle, :checks) == [
               {"API_KEY", "value-one-1"},
               {"CHECK_ONLY", "value-two-2"}
             ]

      assert Secrets.env(bundle, :developer) == [{"API_KEY", "value-one-1"}]
      assert Secrets.env(bundle, :planner) == []
      assert Secrets.env(bundle, :reviewer) == []
      assert Secrets.env(nil, :checks) == []

      assert Secrets.prompt_names(bundle) == %{
               available: ["API_KEY"],
               checks_only: ["CHECK_ONLY"]
             }
    end

    test "redact/2 replaces the value, its JSON form and the lines of a multiline one" do
      pem = "-----BEGIN KEY-----\nabcdefgh12345678\nshort\n-----END KEY-----"

      bundle =
        Bundle.new([
          entry("API_KEY", "tok\"en-1234"),
          entry("PEM", pem),
          entry("LONG", "abcdefgh12345678-and-more")
        ])

      assert Secrets.redact(bundle, "x tok\"en-1234 y") == "x [SECRET:API_KEY] y"
      assert Secrets.redact(bundle, ~s({"a":"tok\\"en-1234"})) == ~s({"a":"[SECRET:API_KEY]"})
      assert Secrets.redact(bundle, "got " <> pem) == "got [SECRET:PEM]"
      assert Secrets.redact(bundle, "line abcdefgh12345678\n") == "line [SECRET:PEM]\n"

      assert Secrets.redact(bundle, "-----BEGIN KEY----- short") ==
               "-----BEGIN KEY----- short"

      # The longest fragment wins where two start at the same place.
      assert Secrets.redact(bundle, "abcdefgh12345678-and-more") == "[SECRET:LONG]"

      assert Secrets.redact(bundle, %{"a" => ["tok\"en-1234", %{"b" => "tok\"en-1234"}], "n" => 1}) ==
               %{"a" => ["[SECRET:API_KEY]", %{"b" => "[SECRET:API_KEY]"}], "n" => 1}

      assert Secrets.redact(nil, "tok\"en-1234") == "tok\"en-1234"
    end

    test "leaked/2 searches each block on its own" do
      bundle = Bundle.new([entry("SHORT_LINES", "abcd\nefgh"), entry("API_KEY", @value)])

      assert Secrets.leaked(bundle, "has #{@value}") == ["API_KEY"]
      assert Secrets.leaked(bundle, ["abcd\nefgh\n"]) == ["SHORT_LINES"]
      assert Secrets.leaked(bundle, ["abcd\n", "efgh\n"]) == []
      assert Secrets.leaked(bundle, ["nothing", "x #{@value}"]) == ["API_KEY"]
      assert Secrets.leaked(nil, ["x"]) == []
    end

    test "inspect shows only the names" do
      bundle = Bundle.new([entry("API_KEY", @value)])
      refute inspect(bundle) =~ @value
      assert inspect(bundle) =~ "API_KEY"
      refute inspect(%Project{secrets: bundle}) =~ @value
      refute inspect(%ProjectSecret{value: @value, encrypted_value: @value}) =~ @value
    end
  end
end
