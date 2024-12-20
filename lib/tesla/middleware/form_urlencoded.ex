defmodule Tesla.Middleware.FormUrlencoded do
  @moduledoc """
  Send request body as `application/x-www-form-urlencoded`.

  Performs encoding of `body` from a `Map` such as `%{"foo" => "bar"}` into
  URL-encoded data.

  Performs decoding of the response into a map when urlencoded and content-type
  is `application/x-www-form-urlencoded`, so `"foo=bar"` becomes
  `%{"foo" => "bar"}`.

  ## Examples

  ```elixir
  defmodule Myclient do
    def client do
      Tesla.client([
        {Tesla.Middleware.FormUrlencoded,
          encode: &Plug.Conn.Query.encode/1,
          decode: &Plug.Conn.Query.decode/1}
      ])
    end
  end

  client = Myclient.client()
  Myclient.post(client, "/url", %{key: :value})
  ```

  ## Options

  - `:decode` - decoding function, defaults to `URI.decode_query/1`
  - `:encode` - encoding function, defaults to `URI.encode_query/1`

  ## Nested Maps

  Natively, nested maps are not supported in the body, so
  `%{"foo" => %{"bar" => "baz"}}` won't be encoded and raise an error.
  Support for this specific case is obtained by configuring the middleware to
  encode (and decode) with `Plug.Conn.Query`

  ```elixir
  defmodule Myclient do
    def client do
      Tesla.client([
        {Tesla.Middleware.FormUrlencoded,
          encode: &Plug.Conn.Query.encode/1,
          decode: &Plug.Conn.Query.decode/1}
      ])
    end
  end

  client = Myclient.client()
  Myclient.post(client, "/url", %{key: %{nested: "value"}})
  ```
  """

  @behaviour Tesla.Middleware

  @content_type "application/x-www-form-urlencoded"

  @impl Tesla.Middleware
  def call(env, next, opts) do
    env
    |> encode(opts)
    |> Tesla.run(next)
    |> case do
      {:ok, env} -> {:ok, decode(env, opts)}
      error -> error
    end
  end

  @doc """
  Encode response body as querystring.

  It is used by `Tesla.Middleware.EncodeFormUrlencoded`.
  """
  def encode(env, opts) do
    if encodable?(env) do
      env
      |> Map.update!(:body, &encode_body(&1, opts))
      |> Tesla.put_headers([{"content-type", @content_type}])
    else
      env
    end
  end

  defp encodable?(%{body: nil}), do: false
  defp encodable?(%{body: %Tesla.Multipart{}}), do: false
  defp encodable?(_), do: true

  defp encode_body(body, _opts) when is_binary(body), do: body
  defp encode_body(body, opts), do: do_encode(body, opts)

  @doc """
  Decode response body as querystring.

  It is used by `Tesla.Middleware.DecodeFormUrlencoded`.
  """
  def decode(env, opts) do
    if decodable?(env) do
      env
      |> Map.update!(:body, &decode_body(&1, opts))
    else
      env
    end
  end

  defp decodable?(env), do: decodable_body?(env) && decodable_content_type?(env)

  defp decodable_body?(env) do
    (is_binary(env.body) && env.body != "") || (is_list(env.body) && env.body != [])
  end

  defp decodable_content_type?(env) do
    case Tesla.get_header(env, "content-type") do
      nil -> false
      content_type -> String.starts_with?(content_type, @content_type)
    end
  end

  defp decode_body(body, opts), do: do_decode(body, opts)

  defp do_encode(data, opts) do
    encoder = Keyword.get(opts, :encode, &URI.encode_query/1)
    encoder.(data)
  end

  defp do_decode(data, opts) do
    decoder = Keyword.get(opts, :decode, &URI.decode_query/1)
    decoder.(data)
  end
end

defmodule Tesla.Middleware.DecodeFormUrlencoded do
  @behaviour Tesla.Middleware

  @impl true
  def call(env, next, opts) do
    opts = opts || []

    with {:ok, env} <- Tesla.run(env, next) do
      {:ok, Tesla.Middleware.FormUrlencoded.decode(env, opts)}
    end
  end
end

defmodule Tesla.Middleware.EncodeFormUrlencoded do
  @behaviour Tesla.Middleware

  @impl true
  def call(env, next, opts) do
    opts = opts || []

    with env <- Tesla.Middleware.FormUrlencoded.encode(env, opts) do
      Tesla.run(env, next)
    end
  end
end
