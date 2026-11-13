defmodule Factory.Secrets.Cipher do
  @moduledoc """
  Encrypts project secrets with AES-256-GCM and the key in `FACTORY_SECRETS_KEY`
  (32 bytes in base64).

  A stored value is `<<version, iv::12 bytes, tag::16 bytes, ciphertext>>`. The
  associated data ties it to its project and name, so a row copied to another
  project or name does not decrypt.
  """

  @version 1
  @generate "Generate one with: openssl rand -base64 32"

  @doc "Decodes a base64 key: `:missing` when there is none."
  @spec decode_key(nil | binary()) :: {:ok, <<_::256>>} | :missing | {:error, String.t()}
  def decode_key(nil), do: :missing

  def decode_key(encoded) when is_binary(encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, <<_::binary-size(32)>> = key} ->
        {:ok, key}

      _ ->
        {:error, "FACTORY_SECRETS_KEY must be 32 bytes encoded in base64. #{@generate}"}
    end
  end

  @doc "The configured key."
  def key, do: decode_key(Application.get_env(:factory, :secrets_key))

  @doc "Raises when a key is configured but is not valid. A missing key is fine."
  def check_key! do
    case key() do
      {:error, message} -> raise ArgumentError, message
      _ -> :ok
    end
  end

  @doc "A short, non-reversible fingerprint of a key, stored with each value it encrypts."
  def fingerprint(key) do
    :crypto.mac(:hmac, :sha256, key, "factory-secrets-key-fingerprint")
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  @doc "The associated data that ties a value to its project and name."
  def aad(project_id, name), do: "factory-secret:v1:#{project_id}:#{name}"

  @doc "Encrypts with the configured key, or `key`."
  def encrypt(plain, aad), do: with({:ok, key} <- configured(), do: encrypt(plain, aad, key))

  def encrypt(plain, aad, key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, aad, 16, true)

    {:ok, <<@version, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>}
  end

  @doc "Decrypts with the configured key, or `key`. `:error` for any failure."
  def decrypt(blob, aad) do
    case configured() do
      {:ok, key} -> decrypt(blob, aad, key)
      _ -> :error
    end
  end

  def decrypt(
        <<@version, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        aad,
        key
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      plain when is_binary(plain) -> {:ok, plain}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decrypt(_blob, _aad, _key), do: :error

  defp configured do
    case key() do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :no_key}
    end
  end
end
