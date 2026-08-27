defmodule Riptide.Logger.JSONFormatter do
  @moduledoc """
  Custom `Logger.Formatter` callback (`format/4`) producing one JSON object per
  line, for production log aggregation. Wired in via
  `config :logger, :default_formatter, format: {__MODULE__, :format}, metadata: :all`
  in `config/prod.exs` only — `config/dev.exs`/`config/test.exs` keep Elixir's
  built-in plain-text formatter, unchanged.

  `metadata: :all` (rather than an explicit key list) means Elixir's own
  automatically-attached metadata (e.g. `:pid`, `:mfa`) can reach this
  function too — values with no `Jason.Encoder` implementation would make
  `Jason.encode!/1` raise, so the `rescue` clause below is load-bearing, not
  just defensive insurance.
  """

  @spec format(Logger.level(), Logger.message(), Logger.Formatter.date_time_ms(), keyword()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    %{timestamp: format_timestamp(timestamp), level: level, message: format_message(message)}
    |> Map.merge(Map.new(metadata))
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _ -> "#{inspect({level, format_message(message), timestamp, metadata})}\n"
  end

  defp format_timestamp({date, {h, mi, s, ms}}) do
    {:ok, naive} = NaiveDateTime.from_erl({date, {h, mi, s}}, {ms * 1000, 3})
    NaiveDateTime.to_iso8601(naive) <> "Z"
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message) when is_list(message), do: IO.chardata_to_string(message)
  defp format_message(message), do: to_string(message)
end
