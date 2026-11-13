defmodule Factory.Shell.Env do
  @moduledoc """
  The minimal environment every process started by `Factory.Shell` gets.

  A child process only inherits the variables listed here (and the names in
  `FACTORY_ENV_PASSTHROUGH`) from the service; everything else — the database
  URL, the secret key base, `MIX_ENV`, the release's variables — is removed.
  What a child inherits is reserved: a project secret cannot use that name.
  """

  @inherited ~w(PATH HOME USER LOGNAME SHELL LANG LANGUAGE TZ TMPDIR SSH_AUTH_SOCK
                HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
                SSL_CERT_FILE SSL_CERT_DIR CLAUDE_CONFIG_DIR CODEX_HOME GH_CONFIG_DIR)
  @inherited_prefixes ~w(LC_ XDG_ MISE_)
  # Not inherited, but set by the factory or the shell, or able to change how a child runs.
  @reserved_extra ~w(PWD OLDPWD SHLVL IFS ENV BASH_ENV CI MIX_TEST_PARTITION TEST_ENV_NUMBER
                     FACTORY_STDIN)
  @reserved_prefixes ~w(FACTORY_ ANTHROPIC_ CLAUDE_ LD_ DYLD_)

  @reserved_names MapSet.new(@inherited ++ @reserved_extra, &String.upcase/1)
  @all_reserved_prefixes @inherited_prefixes ++ @reserved_prefixes

  @name_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc "Whether `name` is a valid environment variable name for a secret (at most 128 characters)."
  def valid_name?(name) when is_binary(name),
    do: String.length(name) <= 128 and Regex.match?(@name_format, name)

  def valid_name?(_), do: false

  @doc "The valid names of `FACTORY_ENV_PASSTHROUGH`."
  def passthrough, do: Enum.filter(configured_passthrough(), &valid_name?/1)

  @doc "The names of `FACTORY_ENV_PASSTHROUGH` that are ignored for not being valid."
  def invalid_passthrough, do: Enum.reject(configured_passthrough(), &valid_name?/1)

  defp configured_passthrough, do: Application.get_env(:factory, :env_passthrough, []) || []

  @doc "Whether a child process inherits the service's `name` (case-sensitive)."
  def inherited?(name) do
    name in @inherited or String.starts_with?(name, @inherited_prefixes) or
      name in passthrough()
  end

  @doc """
  Whether `name` cannot be used by a secret: what children inherit and what the
  factory sets, compared ignoring case.
  """
  def reserved?(name) when is_binary(name) do
    upper = String.upcase(name)

    MapSet.member?(@reserved_names, upper) or
      String.starts_with?(upper, @all_reserved_prefixes) or
      upper in Enum.map(passthrough(), &String.upcase/1)
  end

  @doc "Names in the service's environment a child must not see, except those set in `extra`."
  def removed(extra \\ []) do
    given = MapSet.new(extra, fn {name, _} -> name end)
    allowed = MapSet.new(passthrough())

    for {name, _} <- System.get_env(),
        not (name in @inherited or String.starts_with?(name, @inherited_prefixes) or
               MapSet.member?(allowed, name)),
        not MapSet.member?(given, name),
        do: name
  end

  @doc """
  The `env:` option of `Port.open/2`: removes every variable that is not
  inherited, then sets `extra` (a nil value removes the variable).
  """
  def port_env(extra) do
    removals = for name <- removed(extra), do: {String.to_charlist(name), false}

    sets =
      for {name, value} <- extra,
          do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}

    removals ++ sets
  end

  @doc "The `env:` option of `System.cmd/3` that removes every variable that is not inherited."
  def cmd_env, do: for(name <- removed([]), do: {name, nil})
end
