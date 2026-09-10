defmodule CymphonyElixir.Text do
  @moduledoc """
  Text helpers shared by the log, diagnostic, and status surfaces.

  Agent CLIs and the background daemon both emit terminal-oriented output
  (ANSI colours, cursor moves, carriage returns). Anything that is stored,
  rendered in the dashboard, or posted back to the tracker goes through these
  helpers first so operators read the message instead of the escape codes.
  """

  @ansi_csi_pattern "\\x1B\\[[0-9;]*[A-Za-z]"
  @ansi_escape_pattern "\\x1B."
  @control_byte_pattern "[\\x00-\\x1F\\x7F]"

  @redaction "[REDACTED]"

  # A name is secret-shaped when one of its `_`/`-`/`.` separated segments is
  # exactly one of these words (matched case-insensitively, so the camelCase
  # entries also cover `APIKEY` / `GITHUBTOKEN`). Requiring a *whole* segment is
  # what keeps `MONKEY=banana`, `PATH=/usr/bin`, and `TOKENIZER_PATH=/x` out of
  # the redactor while still catching `ANTHROPIC_API_KEY` and `GH_TOKEN`.
  @secret_words_value "KEYS?|TOKENS?|SECRETS?|PASSWORDS?|PASSWD|PAT|CREDENTIALS?|" <>
                        "apiKeys?|apiTokens?|apiSecrets?|authTokens?|accessTokens?|refreshTokens?|" <>
                        "sessionTokens?|githubTokens?|clientSecrets?|privateKeys?"

  # Header names are handled by their own to-end-of-line pass, which also
  # accepts `=`, so they are kept out of *both* unquoted forms — otherwise
  # `AUTHORIZATION=Bearer x` is redacted twice and renders as
  # `[REDACTED] [REDACTED]`. The quoted forms still need them, because a
  # `"authorization": "Bearer x"` inside a JSON line must not swallow the rest
  # of the line the way the header pass would.
  @header_words "AUTHORIZATION|COOKIES?"
  @secret_words "#{@secret_words_value}|#{@header_words}"

  # `PWD` is the shell's current directory far more often than it is a
  # credential, so it only counts inside a compound name (`DB_PWD`).
  @secret_words_compound_only "PWD"
  @secret_words_colon "#{@secret_words_value}|#{@secret_words_compound_only}"

  @name_start "(?<![A-Za-z0-9_.\\-])"
  @name_segment "[A-Za-z0-9]+[_.\\-]"
  @name_tail "(?:[_.\\-][A-Za-z0-9]+)*"

  # A name suffixed with one of these points at a *location*, not at a value:
  # `SSH_KEY_PATH=/home/me/.ssh/id_rsa` and `TOKEN_FILE=/run/tok` must keep
  # their values or the diagnostic is worthless.
  @name_exempt_suffix "(?<![_.\\-]PATH)(?<![_.\\-]FILE)(?<![_.\\-]DIR)(?<![_.\\-]ID)(?<![_.\\-]NAME)"

  @secret_name "#{@name_start}(?:(?:#{@name_segment})*(?:#{@secret_words})|" <>
                 "(?:#{@name_segment})+(?:#{@secret_words_compound_only}))#{@name_tail}#{@name_exempt_suffix}"

  @secret_name_value "#{@name_start}(?:(?:#{@name_segment})*(?:#{@secret_words_value})|" <>
                       "(?:#{@name_segment})+(?:#{@secret_words_compound_only}))#{@name_tail}#{@name_exempt_suffix}"

  # The bare `NAME: value` form is the one that collides with English prose and
  # with exception messages — `token: rate limit exceeded`,
  # `Unexpected token: '<'`, `KeyError: key: :model` — so it accepts *compound*
  # names only. The `=` and quoted forms keep the single-segment spelling.
  @secret_name_compound "#{@name_start}(?:#{@name_segment})+(?:#{@secret_words_colon})#{@name_tail}#{@name_exempt_suffix}"

  # Header names whose whole value is the credential, including a non-Bearer
  # scheme (`Basic dXNlcjpwYXNz`) and a cookie jar (`a=b; c=d`).
  @header_name "#{@name_start}(?:#{@name_segment})*(?:#{@header_words})#{@name_tail}#{@name_exempt_suffix}"

  # Each pass refuses to re-consume a value an earlier pass already replaced,
  # so a line does not collect `[REDACTED] [REDACTED]`: the quoted-value form
  # is handled once (keeping its quotes, so JSON stays JSON), the unquoted form
  # then excludes anything starting with a quote, and the bare forms skip the
  # literal marker.
  @not_redacted "(?!\\[REDACTED\\])"
  @quoted_value "\"[^\"]*\""
  # Structural characters end an unquoted value: `%{"GH_TOKEN" => 12}` must
  # keep its closing brace.
  @unquoted_value "(?:'[^']*'|[^\\s\",}\\]]+)"
  @any_value "(?:\"[^\"]*\"|'[^']*'|\\S+)"
  # `=>` covers Elixir map inspect output; `:` covers JSON and YAML.
  @quoted_name_separator "\\s*(?::|=>)\\s*"

  # Quoted names first: their values may contain spaces, which the bare `\\S+`
  # forms would leave dangling in the clear, and a quoted match preserves the
  # rest of the line where the header form would consume it.
  @json_assignment_pattern ~s|"(#{@secret_name})"(#{@quoted_name_separator})#{@quoted_value}|
  @quoted_name_pattern ~s|"(#{@secret_name})"(#{@quoted_name_separator})#{@not_redacted}#{@unquoted_value}|
  # The already-redacted guard has to cover the optional scheme word as well:
  # checked after it, the engine just backtracks the scheme away and collapses
  # `Bearer [REDACTED]` into `[REDACTED]` on a second pass.
  # …and it has to tolerate leading whitespace, because the separator's own
  # trailing `\\s*` can backtrack to zero and hand the space to the lookahead.
  @header_pattern "(#{@header_name}\\s*[:=]\\s*)(?!\\s*(?:bearer\\s+)?\\[REDACTED\\]\\s*$)(bearer\\s+)?.*"
  @colon_assignment_pattern "(#{@secret_name_compound})(\\s*:\\s*)#{@not_redacted}#{@any_value}"
  @equals_assignment_pattern "(#{@secret_name_value})(\\s*=>?\\s*)#{@not_redacted}#{@any_value}"

  # Credentials with a recognizable prefix leak without any `NAME=` around them
  # (a bare `sk-…` in a CLI error message, a URL query string, a git remote).
  # Compiled case-insensitively: an uppercased `SK-ANT-…` is the same secret.
  @bare_secret_patterns [
    "sk-[A-Za-z0-9_-]{8,}",
    "lin_api_[A-Za-z0-9_-]+",
    "gh[pousr]_[A-Za-z0-9]{20,}",
    "github_pat_[A-Za-z0-9_]{20,}",
    # GitLab: personal/project/group access tokens (`glpat-`), plus the
    # deploy, runner, feed, OAuth-application and CI job token prefixes.
    "gl(?:pat|dt|rt|ft|oas|cbt|soat|ptt)-[A-Za-z0-9_-]{20,}",
    "xox[a-z]-[A-Za-z0-9-]+",
    "AIza[0-9A-Za-z_-]{35}",
    "ya29\\.[A-Za-z0-9_-]{20,}",
    "1//[A-Za-z0-9_-]{20,}",
    "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]+",
    "AKIA[0-9A-Z]{16}",
    "npm_[A-Za-z0-9]{20,}",
    "hf_[A-Za-z0-9]{20,}"
  ]

  @doc """
  Removes ANSI escape sequences and control bytes from `value`.

  Control bytes include newlines and carriage returns, so callers that need to
  keep line structure must split first and sanitize each line.
  """
  @spec strip_ansi_and_control(String.t()) :: String.t()
  def strip_ansi_and_control(value) when is_binary(value) do
    value
    |> String.replace(Regex.compile!(@ansi_csi_pattern), "")
    |> String.replace(Regex.compile!(@ansi_escape_pattern), "")
    |> String.replace(Regex.compile!(@control_byte_pattern), "")
  end

  @doc """
  Replaces secret-shaped content in `value` with `[REDACTED]`.

  A failing agent CLI routinely prints its own environment. Two paths carry
  that output off the box, and both call this: the retained failure tail
  (retry entry, `/api/v1/state`, dashboard retry queue, tracker abandonment
  comment) and the live harness stdout ring (`GET /api/v1/:issue/harness` and
  the dashboard harness pane). The local debug transcript on disk
  (`~/.cymphony/log/cymphony.log.N`, written by the runner's own stream logger)
  is deliberately **not** redacted — it never leaves the host, and an operator
  debugging an auth failure needs the real bytes.

  Redacted shapes:

  * assignments — `NAME=value`, `NAME => value`, `NAME: value`,
    `"NAME": "value"`, `"NAME" => "value"` — whose name has a whole
    `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`PASSWD`/`PAT`/`CREDENTIAL`/
    `AUTHORIZATION`/`COOKIE` segment, a camelCase spelling of one
    (`apiKey`, `authToken`, `clientSecret`, …), or a compound `PWD`. The name
    is kept so the diagnostic still says *which* variable was involved.
  * `Authorization` and `Cookie` headers, to end of line, with or without a
    scheme — `Bearer`, `Basic`, or none — because the scheme is not the secret.
  * bare credentials with a known vendor prefix: `sk-`, `lin_api_`, `gh[pousr]_`,
    `github_pat_`, GitLab's `glpat-`/`gldt-`/`glrt-`/`glft-`/`gloas-`/`glcbt-`/
    `glsoat-`/`glptt-`, `xox<a>-`, `AIza`, `ya29.`, `1//`, JWTs, `AKIA`, `npm_`,
    `hf_`.

  Two deliberate carve-outs keep diagnostics readable, because the messages
  this protects are the ones operators most need:

  * the bare `NAME: value` form requires a **compound** name, so
    `token: rate limit exceeded`, `Unexpected token: '<'`, and
    `KeyError: key: :model` survive intact. `NAME=value` and the quoted forms
    still accept a single-segment name.
  * a name ending in `_PATH`, `_FILE`, `_DIR`, `_ID`, or `_NAME` keeps its
    value: `SSH_KEY_PATH=/home/me/.ssh/id_rsa` names a location, not a secret.

  This is a redactor, not a secret scanner: an opaque high-entropy string with
  no name and no known prefix still passes through. Ordinary output — URLs,
  code, hex identifiers, words that merely contain "key" — is left alone.

  Cost is superlinear in line length on segmented input, so callers on a hot
  path cap the line first (`truncate_trailing_bytes/2`); port lines can reach
  1 MB.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(value) when is_binary(value) do
    value
    |> String.replace(Regex.compile!(@json_assignment_pattern, "i"), ~s|"\\1"\\2"#{@redaction}"|)
    |> String.replace(Regex.compile!(@quoted_name_pattern, "i"), ~s|"\\1"\\2#{@redaction}|)
    |> String.replace(Regex.compile!(@header_pattern, "i"), "\\1\\2#{@redaction}")
    |> String.replace(Regex.compile!(@colon_assignment_pattern, "i"), "\\1\\2#{@redaction}")
    |> String.replace(Regex.compile!(@equals_assignment_pattern, "i"), "\\1\\2#{@redaction}")
    |> redact_bare_secrets()
  end

  defp redact_bare_secrets(value) do
    Enum.reduce(@bare_secret_patterns, value, fn pattern, acc ->
      String.replace(acc, Regex.compile!(pattern, "i"), @redaction)
    end)
  end

  @doc """
  Caps `value` at `max_bytes`, keeping the head.

  Diagnostics are truncated from the back because every status surface that
  renders them truncates from the front as well (the dashboard retry row cuts
  at 120 characters), so the caller puts the failure first and the oldest
  context last. Cutting on a byte boundary can split a multi-byte codepoint, so
  a truncated result is scrubbed back to valid UTF-8.
  """
  @spec truncate_trailing_bytes(String.t(), non_neg_integer()) :: String.t()
  def truncate_trailing_bytes(value, max_bytes) when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> binary_part(0, max_bytes)
      |> scrub_invalid_utf8()
    end
  end

  @doc """
  Drops byte runs that are not valid UTF-8 from `value`.

  Terminal captures and agent CLI stdout are raw bytes: a partial write, a
  byte-boundary cut, or a non-UTF-8 locale leaves sequences that `IO.puts/2`
  rejects with `ArgumentError` ("not valid character data"). Anything that
  reaches stderr, a flash, or the tracker is scrubbed first so a diagnostic is
  never replaced by a crash.
  """
  @spec scrub_invalid_utf8(String.t()) :: String.t()
  def scrub_invalid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      value
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end
end
