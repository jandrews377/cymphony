defmodule CymphonyElixir.TextTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Text

  describe "strip_ansi_and_control/1" do
    test "removes CSI sequences, other escapes, and control bytes" do
      raw = "\e[2J\e[H\eMstatus\r\n\x00ok\x7F"

      assert Text.strip_ansi_and_control(raw) == "statusok"
    end

    test "leaves plain text untouched" do
      assert Text.strip_ansi_and_control("invalid model selection") == "invalid model selection"
    end
  end

  describe "redact_secrets/1" do
    test "redacts NAME=value assignments and keeps the variable name" do
      assert Text.redact_secrets("LINEAR_API_KEY=lin_api_abcdefghij0123456789") ==
               "LINEAR_API_KEY=[REDACTED]"

      assert Text.redact_secrets("export ANTHROPIC_API_KEY=sk-ant-api03-AAAABBBBCCCC") ==
               "export ANTHROPIC_API_KEY=[REDACTED]"

      assert Text.redact_secrets("GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123") == "GH_TOKEN=[REDACTED]"
      assert Text.redact_secrets("MY_SECRET_TOKEN = abc123") == "MY_SECRET_TOKEN = [REDACTED]"
      assert Text.redact_secrets("db_password=hunter2") == "db_password=[REDACTED]"
      assert Text.redact_secrets("credential.helper=store") == "credential.helper=[REDACTED]"
    end

    test "redacts NAME: value and quoted JSON assignments" do
      # The bare colon form takes compound names only; see the false-positive
      # test below for why `password: hunter2` deliberately survives.
      assert Text.redact_secrets("db_password: hunter2") == "db_password: [REDACTED]"
      assert Text.redact_secrets("anthropic.api-key: sk-live") == "anthropic.api-key: [REDACTED]"

      assert Text.redact_secrets(~s({"api_key": "lin_api_zzzz", "model": "sonnet"})) ==
               ~s({"api_key": "[REDACTED]", "model": "sonnet"})

      # The JSON form must win over the bare `\\S+` forms: its value may contain
      # spaces, which the colon form would leave dangling in the clear.
      assert Text.redact_secrets(~s({"client_secret": "two words here"})) ==
               ~s({"client_secret": "[REDACTED]"})

      assert Text.redact_secrets(~s({"api_key":"packed"})) == ~s({"api_key":"[REDACTED]"})
    end

    test "redacts Authorization headers with any scheme or none" do
      # The scheme word is not the secret: an optional `(bearer\\s+)?` group let
      # `\\S+` eat `Basic` and publish the credential right after it.
      assert Text.redact_secrets("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer [REDACTED]"
      assert Text.redact_secrets("Authorization: Basic dXNlcjpwYXNz") == "Authorization: [REDACTED]"
      assert Text.redact_secrets("Authorization: Token abc123 extra") == "Authorization: [REDACTED]"
      assert Text.redact_secrets("authorization: lin_api_plain") == "authorization: [REDACTED]"
      assert Text.redact_secrets("AUTHORIZATION=Bearer tok123") == "AUTHORIZATION=Bearer [REDACTED]"
      assert Text.redact_secrets("X-Authorization: Bearer x") == "X-Authorization: Bearer [REDACTED]"
      assert Text.redact_secrets("Set-Cookie: session=abc; Path=/") == "Set-Cookie: [REDACTED]"
      assert Text.redact_secrets("Cookie: a=b; c=d") == "Cookie: [REDACTED]"
    end

    test "redacts quoted and map-inspect spellings of a secret name" do
      # A JSON body or an inspected map reaches the same surfaces as an env
      # dump, and neither uses the bare `NAME=value` spelling.
      assert Text.redact_secrets(~s({"headers":{"authorization":"Bearer eyJhbGciOiJ9.eyJzdWIiOiJ9.sig"},"x":"y"})) ==
               ~s({"headers":{"authorization":"[REDACTED]"},"x":"y"})

      assert Text.redact_secrets(~s("Authorization" : "Bearer x")) == ~s("Authorization" : "[REDACTED]")

      assert Text.redact_secrets(~s(%{"ANTHROPIC_AUTH_TOKEN" => "v"})) ==
               ~s(%{"ANTHROPIC_AUTH_TOKEN" => "[REDACTED]"})

      assert Text.redact_secrets(~s(%{"GH_TOKEN" => 12})) == ~s(%{"GH_TOKEN" => [REDACTED]})
      assert Text.redact_secrets(~s({"apiKey":"v"})) == ~s({"apiKey":"[REDACTED]"})
      assert Text.redact_secrets("ANTHROPIC_API_KEY => sk-live-abcdefgh") == "ANTHROPIC_API_KEY => [REDACTED]"
    end

    test "redacts camelCase, run-together, and abbreviated secret names" do
      assert Text.redact_secrets("APIKEY=abc123") == "APIKEY=[REDACTED]"
      assert Text.redact_secrets("GITHUBTOKEN=abc") == "GITHUBTOKEN=[REDACTED]"
      assert Text.redact_secrets("accessToken=abc") == "accessToken=[REDACTED]"
      assert Text.redact_secrets("refreshToken=abc") == "refreshToken=[REDACTED]"
      assert Text.redact_secrets("privateKey=abc") == "privateKey=[REDACTED]"
      assert Text.redact_secrets("GH_PAT=xyz") == "GH_PAT=[REDACTED]"
      assert Text.redact_secrets("PASSWD=secret") == "PASSWD=[REDACTED]"
      assert Text.redact_secrets("DB_PWD=x") == "DB_PWD=[REDACTED]"
    end

    test "redacts bare vendor-prefixed credentials anywhere in the line" do
      cases = [
        {"failed with sk-ant-api03-AAAABBBBCCCCDDDD", "sk-ant"},
        {"failed with SK-ANT-API03-AAAABBBBCCCCDDDD", "SK-ANT"},
        {"key lin_api_abcdefghij0123456789 rejected", "lin_api_"},
        {"remote uses ghp_abcdefghijklmnopqrstuvwxyz0123", "ghp_"},
        {"remote uses gho_abcdefghijklmnopqrstuvwxyz0123", "gho_"},
        {"remote uses ghu_abcdefghijklmnopqrstuvwxyz0123", "ghu_"},
        {"remote uses ghs_abcdefghijklmnopqrstuvwxyz0123", "ghs_"},
        {"remote uses ghr_abcdefghijklmnopqrstuvwxyz0123", "ghr_"},
        {"token github_pat_11ABCDEFG0123456789_abcdefghijklmnop expired", "github_pat_"},
        {"slack xoxb-123456-abcdefghij failed", "xoxb-"},
        {"gemini AIzaSyA12345678901234567890123456789012 denied", "AIzaSy"},
        {"google ya29.a0AfH6SMBabcdefghijklmnop denied", "ya29."},
        {"refresh 1//0gABCDEFGHIJKLMNOPQRST rotated", "1//0g"},
        {"jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3In0.abcdef bad", "eyJhbGci"},
        {"aws AKIAIOSFODNN7EXAMPLE denied", "AKIAIOSFODNN7EXAMPLE"},
        {"npm npm_abcdefghijklmnopqrstuvwxyz denied", "npm_abc"},
        {"hugging hf_abcdefghijklmnopqrstuvwxyz denied", "hf_abc"},
        {"remote uses glpat-abcdefghij0123456789 rejected", "glpat-abc"},
        {"deploy gldt-abcdefghij0123456789 rejected", "gldt-abc"},
        {"runner glrt-abcdefghij0123456789 rejected", "glrt-abc"},
        {"feed glft-abcdefghij0123456789 rejected", "glft-abc"},
        {"oauth gloas-abcdefghij0123456789 rejected", "gloas-abc"},
        {"clone https://oauth2:glpat-abcdefghij0123456789@gitlab.example.com/g/r.git", "glpat-abc"}
      ]

      Enum.each(cases, fn {line, secret_marker} ->
        redacted = Text.redact_secrets(line)
        assert redacted =~ "[REDACTED]", "expected #{inspect(line)} to be redacted"
        refute redacted =~ secret_marker
      end)
    end

    test "leaves ordinary agent output untouched" do
      untouched = [
        "error: unknown provider for model",
        "the monkey ate a banana",
        "MONKEY=banana",
        "TOKENIZER_PATH=/usr/lib/tok",
        "keyboard shortcut: ctrl+k",
        "https://api.linear.app/graphql?first=50",
        "commit a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
        "def key_for(x), do: x",
        ~s({"type":"result","subtype":"success"}),
        ""
      ]

      Enum.each(untouched, fn line ->
        assert Text.redact_secrets(line) == line
      end)
    end

    test "leaves the error messages the tail exists to surface intact" do
      # These are exactly the lines a failure tail and an agy.log are read for.
      # A bare `token:` / `key:` / `secret:` with no name segments is English
      # prose or an exception message, never an assignment, so the colon form
      # takes compound names only.
      untouched = [
        "429 Too Many Requests: token: rate limit exceeded",
        "SyntaxError: Unexpected token: '<'",
        "KeyError: key: :model",
        "password: required",
        "secret: not found",
        "Agent execution terminated due to error.",
        "error: 429 RESOURCE_EXHAUSTED quota exceeded for model gemini-3.7"
      ]

      Enum.each(untouched, fn line ->
        assert Text.redact_secrets(line) == line
      end)
    end

    test "keeps the value of a name that points at a location, not a secret" do
      untouched = [
        "SSH_KEY_PATH=/home/zaali/.ssh/id_rsa",
        "TOKEN_FILE=/run/secrets/tok",
        "API_KEY_DIR=/etc/keys",
        "ACCESS_KEY_ID=display-me",
        "SECRET_NAME=my-secret",
        # PWD is the shell's cwd far more often than a credential; only the
        # compound spelling (DB_PWD) counts.
        "PWD=/Users/zaali/dev/cymphony",
        "PATH=/usr/bin:/bin"
      ]

      Enum.each(untouched, fn line ->
        assert Text.redact_secrets(line) == line
      end)
    end

    test "never stacks a second [REDACTED] onto an already-redacted value" do
      for line <- [
            "AUTHORIZATION=Bearer tok123",
            "X-Authorization: Bearer x",
            ~s({"api_key": "lin_api_zzzz"}),
            "COOKIE=abc"
          ] do
        redacted = Text.redact_secrets(line)
        assert length(String.split(redacted, "[REDACTED]")) == 2, "double redaction in #{inspect(redacted)}"
        assert Text.redact_secrets(redacted) == redacted
      end
    end
  end

  describe "truncate_trailing_bytes/2" do
    test "returns the value untouched when it fits the cap" do
      assert Text.truncate_trailing_bytes("abcdef", 6) == "abcdef"
    end

    test "keeps the head when the value exceeds the cap" do
      assert Text.truncate_trailing_bytes("real error\nnoise", 10) == "real error"
    end

    test "drops the trailing bytes of a codepoint split by the cut" do
      # "𝄞" is 4 bytes; cutting to the first 6 bytes leaves 2 of them.
      assert Text.truncate_trailing_bytes("abc𝄞", 6) == "abc"
      assert String.valid?(Text.truncate_trailing_bytes("abc𝄞", 6))
    end

    test "returns an empty string for a zero cap" do
      assert Text.truncate_trailing_bytes("abc", 0) == ""
    end
  end

  describe "scrub_invalid_utf8/1" do
    test "returns valid input unchanged" do
      assert Text.scrub_invalid_utf8("plain ✓ text") == "plain ✓ text"
    end

    test "drops byte runs that are not valid UTF-8" do
      scrubbed = Text.scrub_invalid_utf8("ok-" <> <<0xE2, 0x9C>> <> "-mid-" <> <<0xFF>> <> "-end")

      assert scrubbed == "ok--mid--end"
      assert String.valid?(scrubbed)
    end

    test "produces a binary IO.puts/2 accepts" do
      scrubbed = Text.scrub_invalid_utf8(<<0x9C>> <> "tail")

      assert ExUnit.CaptureIO.capture_io(fn -> IO.puts(scrubbed) end) == "tail\n"
    end
  end
end
