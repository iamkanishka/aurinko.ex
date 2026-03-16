defmodule Aurinko.Config do
  @moduledoc """
  Configuration management for Aurinko.

  All options can be set in `config.exs` or passed per-request.

  ## Options

  - `:client_id` (string, required) — Aurinko application client ID
  - `:client_secret` (string, required) — Aurinko application client secret
  - `:base_url` (string) — Base URL for the Aurinko API. Default: `https://api.aurinko.io/v1`
  - `:timeout` (pos_integer) — HTTP request timeout in milliseconds. Default: `30_000`
  - `:retry_attempts` (non_neg_integer) — Number of retry attempts. Default: `3`
  - `:retry_delay` (pos_integer) — Base retry delay in ms (exponential backoff). Default: `500`
  - `:pool_size` (pos_integer) — HTTP connection pool size. Default: `10`
  - `:log_level` (atom) — One of `:debug`, `:info`, `:warning`, `:error`, `:none`. Default: `:info`
  """

  @schema_keys [
    client_id: [
      type: :string,
      required: true,
      doc: "Aurinko application client ID"
    ],
    client_secret: [
      type: :string,
      required: true,
      doc: "Aurinko application client secret"
    ],
    base_url: [
      type: :string,
      default: "https://api.aurinko.io/v1",
      doc: "Base URL for the Aurinko API"
    ],
    timeout: [
      type: :pos_integer,
      default: 30_000,
      doc: "HTTP request timeout in milliseconds"
    ],
    retry_attempts: [
      type: :non_neg_integer,
      default: 3,
      doc: "Number of retry attempts for failed requests"
    ],
    retry_delay: [
      type: :pos_integer,
      default: 500,
      doc: "Base delay between retries in milliseconds (uses exponential backoff)"
    ],
    pool_size: [
      type: :pos_integer,
      default: 10,
      doc: "HTTP connection pool size"
    ],
    log_level: [
      type: {:in, [:debug, :info, :warning, :error, :none]},
      default: :info,
      doc: "Logging verbosity level"
    ]
  ]

  @type t :: %{
          client_id: String.t(),
          client_secret: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          retry_attempts: non_neg_integer(),
          retry_delay: pos_integer(),
          pool_size: pos_integer(),
          log_level: :debug | :info | :warning | :error | :none
        }

  @doc """
  Loads and validates configuration from application env.
  Raises `Aurinko.ConfigError` if required keys are missing or invalid.
  """
  @spec load!() :: t()
  def load! do
    all_opts = Application.get_all_env(:aurinko)
    schema = NimbleOptions.new!(@schema_keys)
    known_keys = Keyword.keys(@schema_keys)
    opts = Keyword.take(all_opts, known_keys)

    case NimbleOptions.validate(opts, schema) do
      {:ok, config} ->
        Map.new(config)

      {:error, %NimbleOptions.ValidationError{} = err} ->
        raise Aurinko.ConfigError, message: Exception.message(err)
    end
  end

  @doc """
  Merges runtime overrides on top of the base config.
  """
  @spec merge(t(), keyword()) :: t()
  def merge(base, overrides) when is_map(base) and is_list(overrides) do
    Map.merge(base, Map.new(overrides))
  end

  @doc """
  Returns the configured base URL.
  """
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:aurinko, :base_url, "https://api.aurinko.io/v1")
  end
end
