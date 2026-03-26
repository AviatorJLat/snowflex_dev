# SnowflexDev

A drop-in development replacement for [Snowflex](https://github.com/pepsico-ecommerce/snowflex) that gives Elixir developers Snowflake access in local development using browser-based SSO -- no keypairs, no security integrations, no admin involvement.

SnowflexDev implements the full `DBConnection` behaviour and Ecto adapter interface, so consuming Phoenix apps can swap between SnowflexDev (dev) and Snowflex (prod) by changing only config values. Zero application code changes.

Under the hood, it bridges Elixir and Python via an Erlang Port, using Python's `snowflake-connector-python` with `externalbrowser` SSO authentication.

## Why?

Snowflex uses keypair authentication in production, which requires generating keys and configuring a Snowflake security integration (`ACCOUNTADMIN` access). When admins are unavailable or the setup is blocked, local development stalls.

Python's Snowflake connector supports `externalbrowser` SSO natively -- it opens your browser, you authenticate with your existing credentials, and you're connected. No Snowflake-side setup required.

SnowflexDev wraps this in a proper Ecto adapter so your app code doesn't know the difference.

## Prerequisites

- Elixir ~> 1.18
- Python 3.9+
- A Snowflake account with browser-based SSO enabled

## Installation

Add `snowflex_dev` as a dev-only dependency in your `mix.exs`:

```elixir
def deps do
  [
    {:snowflex_dev, git: "https://github.com/AviatorJLat/snowflex_dev.git", only: :dev}
  ]
end
```

Then fetch and set up:

```bash
mix deps.get
mix snowflex_dev.setup
```

The setup task will:
1. Find Python 3.9+ on your system
2. Create a virtual environment at `_snowflex_dev/venv/`
3. Install `snowflake-connector-python` with secure local storage
4. Verify the installation

## Configuration

Add to your `config/dev.exs`:

```elixir
config :my_app, MyApp.Repo,
  adapter: SnowflexDev,
  account: "your-account",
  user: "your.email@company.com",
  warehouse: "YOUR_WH",
  database: "YOUR_DB",
  schema: "PUBLIC",
  role: "YOUR_ROLE"
```

Your `config/prod.exs` continues to use Snowflex as before:

```elixir
config :my_app, MyApp.Repo,
  adapter: Snowflex,
  # ... your production Snowflex config
```

No changes to your Repo module or application code are needed.

### Configuration Options

| Option | Required | Description |
|--------|----------|-------------|
| `account` | Yes | Your Snowflake account identifier |
| `user` | Yes | Your Snowflake username (typically email) |
| `warehouse` | Yes | Snowflake warehouse to use |
| `database` | Yes | Default database |
| `schema` | No | Default schema (defaults to `"PUBLIC"`) |
| `role` | No | Snowflake role to assume |
| `python_path` | No | Path to Python binary (defaults to `_snowflex_dev/venv/bin/python3`) |
| `pool_size` | No | Number of connections (defaults to DBConnection default) |

## Usage

Once configured, use your Repo exactly as you would with Snowflex:

```elixir
# Ecto queries work identically
MyApp.Repo.all(from u in User, where: u.active == true)

MyApp.Repo.insert(%User{name: "Jane", active: true})

MyApp.Repo.update(changeset)

MyApp.Repo.delete(user)

# Raw SQL via Ecto
Ecto.Adapters.SQL.query!(MyApp.Repo, "SELECT CURRENT_WAREHOUSE()")
```

On first connection, your browser will open for SSO authentication. Credentials are cached locally so subsequent connections authenticate automatically.

## How It Works

```
Elixir App
    |
    v
Ecto.Repo (your existing code, unchanged)
    |
    v
SnowflexDev (Ecto.Adapter + DBConnection behaviour)
    |
    v
Erlang Port ({:packet, 4} length-prefixed JSON protocol)
    |
    v
Python worker (long-lived process)
    |
    v
snowflake-connector-python (externalbrowser SSO)
    |
    v
Snowflake
```

- **Process isolation**: The Python process runs outside the BEAM. A Python crash cannot take down your Elixir application -- the connection pool recovers automatically.
- **1:1 mapping**: Each DBConnection pool slot owns one Python process. No GIL contention.
- **Chunked transfer**: Large result sets are transferred in chunks to prevent memory exhaustion.
- **Zombie prevention**: Python processes monitor their parent PID and self-terminate if the BEAM exits.

## Supported Snowflake Types

SnowflexDev decodes Snowflake types to the same Elixir types as Snowflex:

| Snowflake Type | Elixir Type |
|----------------|-------------|
| `FIXED` (integers) | `integer` |
| `FIXED` (decimals) | `Decimal` |
| `REAL` | `float` |
| `VARCHAR` / `TEXT` | `String` |
| `BOOLEAN` | `boolean` |
| `DATE` | `Date` |
| `TIME` | `Time` |
| `TIMESTAMP_NTZ` | `NaiveDateTime` |
| `TIMESTAMP_LTZ` | `DateTime` |
| `TIMESTAMP_TZ` | `DateTime` |

## Troubleshooting

### Python not found

```
** (SnowflexDev.Error) Python not found at: _snowflex_dev/venv/bin/python3
```

Run `mix snowflex_dev.setup` to create the Python environment. If Python isn't on your PATH:

```bash
# macOS
brew install python

# Ubuntu/Debian
sudo apt install python3 python3-venv
```

### Connector not importable

```
** (SnowflexDev.Error) snowflake-connector-python not importable
```

Re-run `mix snowflex_dev.setup`. If behind a corporate proxy:

```bash
HTTPS_PROXY=http://proxy:port mix snowflex_dev.setup
```

### SSO browser popup doesn't appear

The `externalbrowser` authenticator opens your default browser. If it doesn't appear:
- Check that your Snowflake account has browser-based SSO enabled
- Ensure no browser popup blocker is interfering
- The first connection has an extended timeout (60s) to allow for authentication

### Connection timeout on startup

SSO authentication can take 30+ seconds if you need to interact with the browser. The GenServer timeout is configured to accommodate this. If you're still timing out, check your network connectivity to Snowflake.

## Limitations

- **Dev/test only** -- not designed for production use (Snowflex handles that)
- **No transaction support** -- Snowflake doesn't support traditional transactions; matches Snowflex's behaviour
- **No migration support** -- use Snowflex or Snowflake's web UI for DDL
- **macOS/Linux only** -- Windows support is not yet implemented

## Architecture

SnowflexDev is built in four layers:

1. **Python Bridge** -- Erlang Port with `{:packet, 4}` JSON protocol, stdout isolation, and PPID monitoring
2. **Transport GenServer** -- Manages Port lifecycle, converts async Port messages to sync GenServer.call
3. **DBConnection Adapter** -- Full `DBConnection` behaviour with type decoding matching Snowflex
4. **Ecto Adapter** -- `Ecto.Adapter`, `Ecto.Adapter.Queryable`, and `Ecto.Adapter.Schema` behaviours with Snowflake SQL dialect generation

## Built With

This project was developed with the assistance of [Claude Code](https://claude.ai/claude-code) using the [GSD (Get Shit Done)](https://github.com/gsd-build/get-shit-done) workflow.

## License

See [LICENSE](LICENSE) for details.
