defmodule Aurinko.Webhook.VerifierTest do
  use ExUnit.Case, async: true

  alias Aurinko.Webhook.Verifier

  @secret "super_secret_webhook_key"
  @body ~s({"eventType":"email.new","accountId":123})

  describe "verify/3" do
    test "returns :ok for a valid signature" do
      signature = Verifier.sign(@body, @secret)
      assert :ok = Verifier.verify(@body, signature, secret: @secret)
    end

    test "returns :ok without sha256= prefix" do
      raw_sig =
        :crypto.mac(:hmac, :sha256, @secret, @body)
        |> Base.encode16(case: :lower)

      assert :ok = Verifier.verify(@body, raw_sig, secret: @secret)
    end

    test "returns {:error, :invalid_signature} for wrong signature" do
      assert {:error, :invalid_signature} =
               Verifier.verify(@body, "sha256=deadbeef", secret: @secret)
    end

    test "returns {:error, :invalid_signature} for nil signature" do
      assert {:error, :invalid_signature} = Verifier.verify(@body, nil, secret: @secret)
    end

    test "returns {:error, :invalid_signature} for empty signature" do
      assert {:error, :invalid_signature} = Verifier.verify(@body, "", secret: @secret)
    end

    test "returns {:error, :invalid_signature} when no secret configured" do
      Application.delete_env(:aurinko, :webhook_secret)
      sig = Verifier.sign(@body, @secret)
      assert {:error, :invalid_signature} = Verifier.verify(@body, sig)
    end

    test "returns {:error, :invalid_signature} for tampered body" do
      signature = Verifier.sign(@body, @secret)
      tampered = @body <> " extra"
      assert {:error, :invalid_signature} = Verifier.verify(tampered, signature, secret: @secret)
    end

    test "reads secret from application config" do
      Application.put_env(:aurinko, :webhook_secret, @secret)
      signature = Verifier.sign(@body, @secret)
      assert :ok = Verifier.verify(@body, signature)
    after
      Application.delete_env(:aurinko, :webhook_secret)
    end

    test "is case-insensitive for hex signature" do
      sig_upper =
        :crypto.mac(:hmac, :sha256, @secret, @body)
        |> Base.encode16(case: :upper)

      assert :ok = Verifier.verify(@body, sig_upper, secret: @secret)
    end
  end

  describe "sign/2" do
    test "produces sha256= prefixed hex string" do
      sig = Verifier.sign(@body, @secret)
      assert String.starts_with?(sig, "sha256=")
      assert String.length(sig) == 7 + 64
    end

    test "is deterministic" do
      sig1 = Verifier.sign(@body, @secret)
      sig2 = Verifier.sign(@body, @secret)
      assert sig1 == sig2
    end

    test "different bodies produce different signatures" do
      sig1 = Verifier.sign("body_a", @secret)
      sig2 = Verifier.sign("body_b", @secret)
      refute sig1 == sig2
    end

    test "different secrets produce different signatures" do
      sig1 = Verifier.sign(@body, "secret_one")
      sig2 = Verifier.sign(@body, "secret_two")
      refute sig1 == sig2
    end
  end
end

defmodule Aurinko.Webhook.HandlerTest do
  use ExUnit.Case, async: true

  alias Aurinko.Webhook.Handler

  defmodule TestHandler do
    @behaviour Aurinko.Webhook.Handler

    @impl true
    def handle_event("email.new", payload, _meta) do
      send(self(), {:handled, "email.new", payload})
      :ok
    end

    def handle_event("calendar.updated", _payload, _meta) do
      {:error, :deliberate_error}
    end

    def handle_event(_event, _payload, _meta), do: :ok
  end

  @body ~s({"eventType":"email.new","accountId":123,"data":{"subject":"Hello"}})

  describe "dispatch/4" do
    test "dispatches a valid payload to the handler" do
      assert :ok = Handler.dispatch(TestHandler, @body)
      assert_receive {:handled, "email.new", %{"accountId" => 123}}
    end

    test "verifies signature when provided" do
      secret = "dispatch_test_secret"
      Application.put_env(:aurinko, :webhook_secret, secret)
      sig = Aurinko.Webhook.Verifier.sign(@body, secret)

      assert :ok = Handler.dispatch(TestHandler, @body, sig)
    after
      Application.delete_env(:aurinko, :webhook_secret)
    end

    test "rejects invalid signature" do
      Application.put_env(:aurinko, :webhook_secret, "real_secret")
      result = Handler.dispatch(TestHandler, @body, "sha256=invalid")
      assert {:error, :invalid_signature} = result
    after
      Application.delete_env(:aurinko, :webhook_secret)
    end

    test "returns handler errors" do
      body = ~s({"eventType":"calendar.updated"})
      result = Handler.dispatch(TestHandler, body)
      assert {:error, :deliberate_error} = result
    end

    test "returns error for invalid JSON" do
      result = Handler.dispatch(TestHandler, "not json")
      assert {:error, _} = result
    end

    test "skips verification when no signature provided" do
      assert :ok = Handler.dispatch(TestHandler, @body)
    end
  end
end
