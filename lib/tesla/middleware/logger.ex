defmodule Tesla.Middleware.Logger.Formatter do
  @moduledoc false

  # Heavily based on Elixir's Logger.Formatter
  # https://github.com/elixir-lang/elixir/blob/v1.6.4/lib/logger/lib/logger/formatter.ex

  @default_format "$method $url -> $status ($time ms)"
  @keys ~w(method url status time query)

  @type format :: [atom | binary]

  @spec compile(binary | nil) :: format
  @spec compile(pattern) :: pattern when pattern: function | {module, fun :: atom}
  def compile(nil), do: compile(@default_format)
  def compile(fun) when is_function(fun), do: fun
  def compile({mod, fun}) when is_atom(mod) and is_atom(fun), do: {mod, fun}

  def compile(binary) do
    ~r/(?<h>)\$[a-z]+(?<t>)/
    |> Regex.split(binary, on: [:h, :t], trim: true)
    |> Enum.map(&compile_key/1)
  end

  defp compile_key("$" <> key) when key in @keys, do: String.to_atom(key)
  defp compile_key("$" <> key), do: raise(ArgumentError, "$#{key} is an invalid format pattern.")
  defp compile_key(part), do: part

  @spec format(
          Tesla.Env.t(),
          Tesla.Env.result(),
          integer,
          format | function | {module, atom}
        ) :: IO.chardata()
  def format(request, response, time, fun) when is_function(fun) do
    apply(fun, [request, response, time])
  end

  def format(request, response, time, {mod, fun}) do
    apply(mod, fun, [request, response, time])
  end

  def format(request, response, time, format) do
    Enum.map(format, &output(&1, request, response, time))
  end

  defp output(:query, env, _, _) do
    encoding = Keyword.get(env.opts, :query_encoding, :www_form)

    Tesla.encode_query(env.query, encoding)
  end

  defp output(:method, env, _, _), do: env.method |> to_string() |> String.upcase()
  defp output(:url, env, _, _), do: env.url
  defp output(:status, _, {:ok, env}, _), do: to_string(env.status)
  defp output(:status, _, {:error, reason}, _), do: "error: " <> inspect(reason)
  defp output(:time, _, _, time), do: :io_lib.format("~.3f", [time / 1000])
  defp output(binary, _, _, _), do: binary
end

defmodule Tesla.Middleware.Logger do
  @moduledoc ~S"""
  Log requests using Elixir's Logger.

  With the default settings it logs request method, URL, response status, and
  time taken in milliseconds.

  ## Examples

  ```elixir
  defmodule MyClient do
    def client do
      Tesla.client([Tesla.Middleware.Logger])
    end
  end
  ```

  ## Options

  - `:level` - custom function for calculating log level or atom for fixed level (see below)
  - `:log_level` - (deprecated) custom function for calculating log level (see below)
  - `:filter_headers` - sanitizes sensitive headers before logging in debug mode (see below)
  - `:debug` - use `Logger.debug/2` to log request/response details
  - `:format` - custom string template or function for log message (see below)

  ## Custom log format

  The default log format is `"$method $url -> $status ($time ms)"`
  which shows in logs like:

  ```elixir
  2018-03-25 18:32:40.397 [info]  GET https://bitebot.io -> 200 (88.074 ms)
  ```

  It can be changed globally with config:

  ```elixir
  config :tesla, Tesla.Middleware.Logger, format: "$method $url ====> $status / time=$time"
  ```

  Or you can customize this setting by providing your own `format` function:

  ```elixir
  defmodule MyClient do
    def client do
      Tesla.client([
        {Tesla.Middleware.Logger, format: &my_format/3}
      ])
    end

    def my_format(request, response, time) do
      "request=#{inspect(request)} response=#{inspect(response)} time=#{time}\n"
    end
  end
  ```

  ## Custom log levels

  By default, the following log levels will be used:

  - `:error` - for errors, 5xx and 4xx responses
  - `:warn` or `:warning` - for 3xx responses
  - `:info` - for 2xx responses

  You can customize this setting by providing your own level function that accepts
  both success and error cases:

  ```elixir
  defmodule MyClient do
    def client do
      Tesla.client([
        {Tesla.Middleware.Logger, level: &my_level/1}
      ])
    end

    def my_level({:ok, env}) do
      case env.status do
        404 -> :info
        _ -> :default
      end
    end

    def my_level({:error, _reason}) do
      :error
    end
  end
  ```

  Or provide a fixed log level:

  ```elixir
  defmodule MyClient do
    def client do
      Tesla.client([
        {Tesla.Middleware.Logger, level: :debug}
      ])
    end
  end
  ```

  You can also use the deprecated `log_level` option (will show a deprecation warning):

  ```elixir
  defmodule MyClient do
    def client do
      Tesla.client([
        {Tesla.Middleware.Logger, log_level: &my_log_level/1}
      ])
    end

    def my_log_level(env) do
      case env.status do
        404 -> :info
        _ -> :default
      end
    end
  end
  ```

  To disable the deprecation warning for `:log_level`, add this to your config:

  ```elixir
  # config/config.exs
  config :tesla, disable_log_level_warning: true
  ```

  ## Logger Debug output

  `Tesla` will use `Logger.debug/2` to log request & response details using
  the `:debug` option. It will require to set the `Logger` log level to `:debug`
  in your configuration, example:

  ```elixir
  # config/dev.exs
  config :logger, level: :debug
  ```

  If you want to disable detailed request/response logging but keep the
  `:debug` log level (i.e. in development) you can set `debug: false` in your
  config:

  ```elixir
  # config/dev.local.exs
  config :tesla, Tesla.Middleware.Logger, debug: false
  ```

  Note that the logging configuration is evaluated at compile time,
  so Tesla must be recompiled for the configuration to take effect:

  ```shell
  mix deps.clean --build tesla
  mix deps.compile tesla
  ```

  In order to be able to set `:debug` at runtime we can
  pass it as a option to the middleware at runtime.

  ```elixir
  def client do
    middleware = [
      # ...
      {Tesla.Middleware.Logger, debug: false}
    ]

    Tesla.client(middleware)
  end
  ```

  ### Filter headers

  To sanitize sensitive headers such as `authorization` in
  debug logs, add them to the `:filter_headers` option.
  `:filter_headers` expects a list of header names as strings.

  ```elixir
  # config/dev.local.exs
  config :tesla, Tesla.Middleware.Logger,
    filter_headers: ["authorization"]
  ```
  """

  @behaviour Tesla.Middleware

  alias Tesla.Middleware.Logger.Formatter

  @config Application.compile_env(:tesla, __MODULE__, [])

  @format Formatter.compile(@config[:format])

  @type log_level :: :info | :warn | :warning | :error

  if Version.compare(System.version(), "1.11.0") == :lt do
    @warning_level :warn
  else
    @warning_level :warning
  end

  require Logger

  @impl Tesla.Middleware
  def call(env, next, opts) do
    {time, response} = :timer.tc(Tesla, :run, [env, next])

    config = Keyword.merge(@config, opts)

    optional_runtime_format = Keyword.get(config, :format)

    format =
      if optional_runtime_format, do: Formatter.compile(optional_runtime_format), else: @format

    level = log_level(response, config)
    Logger.log(level, fn -> Formatter.format(env, response, time, format) end)

    if Keyword.get(config, :debug, true) do
      Logger.debug(fn -> debug(env, response, config) end)
    end

    response
  end

  defp log_level(response, config) do
    log_level_option = Keyword.get(config, :log_level)
    level_option = Keyword.get(config, :level)

    cond do
      log_level_option != nil and level_option != nil ->
        raise ArgumentError, "cannot provide both :log_level and :level options"

      log_level_option != nil ->
        if not Application.get_env(:tesla, :disable_log_level_warning, false) do
          IO.warn(":log_level option is deprecated, use :level option instead")
        end

        apply_level_function(response, &legacy_log_level_wrapper(log_level_option, &1))

      level_option != nil ->
        apply_level_function(response, level_option)

      true ->
        default_response_log_level(response)
    end
  end

  defp apply_level_function(response, fun) when is_function(fun) do
    case fun.(response) do
      :default -> default_response_log_level(response)
      warning when warning in [:warn, :warning] -> @warning_level
      level -> level
    end
  end

  defp apply_level_function(_response, atom) when is_atom(atom) do
    case atom do
      warning when warning in [:warn, :warning] -> @warning_level
      level -> level
    end
  end

  # Wrapper function to adapt old log_level functions to the new response tuple format
  defp legacy_log_level_wrapper(log_level_function, {:ok, env})
       when is_function(log_level_function) do
    log_level_function.(env)
  end

  defp legacy_log_level_wrapper(log_level_atom, {:ok, _env}) when is_atom(log_level_atom) do
    log_level_atom
  end

  defp legacy_log_level_wrapper(_log_level_function, {:error, _}) do
    :error
  end

  defp default_response_log_level({:error, _}), do: :error
  defp default_response_log_level({:ok, env}), do: default_log_level(env)

  @spec default_log_level(Tesla.Env.t()) :: log_level
  def default_log_level(env) do
    cond do
      env.status >= 400 -> :error
      env.status >= 300 -> @warning_level
      true -> :info
    end
  end

  @debug_no_query "(no query)"
  @debug_no_headers "(no headers)"
  @debug_no_body "(no body)"
  @debug_stream "[Elixir.Stream]"

  defp debug(request, {:ok, response}, config) do
    [
      "\n>>> REQUEST >>>\n",
      debug_query(request.query),
      ?\n,
      debug_headers(request.headers, config),
      ?\n,
      debug_body(request.body),
      ?\n,
      "\n<<< RESPONSE <<<\n",
      debug_headers(response.headers, config),
      ?\n,
      debug_body(response.body)
    ]
  end

  defp debug(request, {:error, error}, config) do
    [
      "\n>>> REQUEST >>>\n",
      debug_query(request.query),
      ?\n,
      debug_headers(request.headers, config),
      ?\n,
      debug_body(request.body),
      ?\n,
      "\n<<< RESPONSE ERROR <<<\n",
      inspect(error)
    ]
  end

  defp debug_query([]), do: @debug_no_query

  defp debug_query(query) do
    query
    |> Enum.flat_map(&Tesla.encode_pair/1)
    |> Enum.map(fn {k, v} -> ["Query: ", to_string(k), ": ", to_string(v), ?\n] end)
  end

  defp debug_headers([], _config), do: @debug_no_headers

  defp debug_headers(headers, config) do
    filtered = Keyword.get(config, :filter_headers, [])

    Enum.map(headers, fn {k, v} ->
      v = if k in filtered, do: "[FILTERED]", else: v
      [k, ": ", v, ?\n]
    end)
  end

  defp debug_body(nil), do: @debug_no_body
  defp debug_body([]), do: @debug_no_body
  defp debug_body(%Stream{}), do: @debug_stream
  defp debug_body(stream) when is_function(stream), do: @debug_stream

  defp debug_body(%Tesla.Multipart{} = mp) do
    [
      "[Tesla.Multipart]\n",
      "boundary: ",
      mp.boundary,
      ?\n,
      "content_type_params: ",
      inspect(mp.content_type_params),
      ?\n
      | Enum.map(mp.parts, &[inspect(&1), ?\n])
    ]
  end

  defp debug_body(data) when is_binary(data) or is_list(data), do: data
  defp debug_body(term), do: inspect(term)
end
