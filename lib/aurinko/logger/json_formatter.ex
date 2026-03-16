defmodule Aurinko.Logger.JSONFormatter do
  @moduledoc """
  Structured JSON log formatter for production and staging environments.

  Produces one JSON object per log line, compatible with Datadog, Loki,
  Google Cloud Logging, and other log aggregation pipelines.

  ## Sample output

      {"time":"2024-06-01T14:23:01.456Z","level":"info","msg":"[Aurinko] ← ok 42ms GET /email/messages","pid":"<0.234.0>","module":"Aurinko.HTTP.Client","request_id":"req-abc123"}

  ## Usage

  Configure in `prod.exs` / `staging.exs`:

      config :logger, :console,
        format: {Aurinko.Logger.JSONFormatter, :format},
        metadata: [:request_id, :module, :function, :line, :pid]
  """

  # timestamp is {{year,month,day},{hour,min,sec,ms}} as passed by the Logger backend
  @type log_timestamp :: {{pos_integer(), 1..12, 1..31}, {0..23, 0..59, 0..59, 0..999}}

  @spec format(Logger.level(), Logger.message(), log_timestamp(), keyword()) :: binary()
  def format(level, message, timestamp, metadata) do
    %{
      time: format_timestamp(timestamp),
      level: level,
      msg: IO.iodata_to_binary(message),
      pid: inspect(Keyword.get(metadata, :pid, self())),
      module: Keyword.get(metadata, :module),
      function: Keyword.get(metadata, :function),
      line: Keyword.get(metadata, :line),
      request_id: Keyword.get(metadata, :request_id)
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _ -> "#{level} #{message}\n"
  end

  defp format_timestamp({date, {h, m, s, ms}}) do
    {year, month, day} = date

    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [year, month, day, h, m, s, ms]
    )
    |> IO.iodata_to_binary()
  end
end
