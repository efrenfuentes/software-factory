# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :factory,
  ecto_repos: [Factory.Repo],
  generators: [timestamp_type: :utc_datetime]

# Background jobs. `agents` bounds how many issues are worked on at once.
config :factory, Oban,
  repo: Factory.Repo,
  queues: [poll: 1, agents: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(90)},
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Factory.Workers.PollWorker}]}
  ]

# Adapters for the outside world; tests swap these for fakes.
config :factory,
  github: Factory.GitHub.CLI,
  agent_runner: Factory.Agents.ClaudeCLI,
  workspace: Factory.Workspace.Git,
  gates: Factory.Gates.Shell

# Configures the endpoint
config :factory, FactoryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FactoryWeb.ErrorHTML, json: FactoryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Factory.PubSub,
  live_view: [signing_salt: "CFyZQWU7"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :factory, Factory.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  factory: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  factory: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
