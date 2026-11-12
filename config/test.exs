import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :factory, Factory.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD") || "",
  hostname: "localhost",
  database: "factory_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :factory, FactoryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "V/IN9AGZtnIRVozadkKhrwQHxFaw7TsCkgMHJtH61+1sdJbVubxdRivoIOVCqtvr",
  server: false

# In test we don't send emails
config :factory, Factory.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :factory, Oban, testing: :manual

config :factory,
  github: Factory.Fakes.GitHub,
  agent_runners: %{claude: Factory.Fakes.Agent, codex: Factory.Fakes.Agent},
  workspace: Factory.Fakes.Workspace,
  gates: Factory.Fakes.Gates
