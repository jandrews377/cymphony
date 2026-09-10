defmodule CymphonyElixir.Orchestrator.TokensTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Orchestrator.Tokens

  @ts ~U[2026-05-29 00:00:00Z]

  describe "apply_token_delta/2" do
    test "accumulates each field and clamps at zero" do
      totals = %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 2}
      delta = %{input_tokens: 3, output_tokens: 4, total_tokens: 7, seconds_running: 1}

      assert Tokens.apply_token_delta(totals, delta) ==
               %{input_tokens: 13, output_tokens: 9, total_tokens: 22, seconds_running: 3}
    end

    test "missing accumulator/seconds default to zero" do
      assert %{input_tokens: 1, seconds_running: 0} =
               Tokens.apply_token_delta(%{}, %{input_tokens: 1, output_tokens: 1, total_tokens: 2})
    end

    test "clamps accumulated totals at zero when the delta is negative" do
      totals = %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4}
      delta = %{input_tokens: -5, output_tokens: -9, total_tokens: -8, seconds_running: -10}

      assert Tokens.apply_token_delta(totals, delta) ==
               %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    end
  end

  describe "extract_token_delta/2" do
    test "derives delta from absolute usage minus last-reported, tracking reported" do
      update = %{
        :event => :u,
        :timestamp => @ts,
        "tokenUsage" => %{"total" => %{"input_tokens" => 100, "output_tokens" => 40, "total_tokens" => 140}}
      }

      running = %{
        last_reported_input_tokens: 70,
        last_reported_output_tokens: 30,
        last_reported_total_tokens: 100
      }

      delta = Tokens.extract_token_delta(running, update)
      assert delta.input_tokens == 30
      assert delta.output_tokens == 10
      assert delta.total_tokens == 40
      assert delta.input_reported == 100
      assert delta.total_reported == 140
    end

    test "nil running entry is treated as a zero baseline" do
      update = %{
        :event => :u,
        :timestamp => @ts,
        "tokenUsage" => %{"total" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}
      }

      delta = Tokens.extract_token_delta(nil, update)
      assert delta.input_tokens == 5
      assert delta.total_tokens == 7
    end

    test "non-increasing usage yields zero delta but still records reported" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"input_tokens" => 50}}}
      running = %{last_reported_input_tokens: 80}

      delta = Tokens.extract_token_delta(running, update)
      assert delta.input_tokens == 0
      assert delta.input_reported == 50
      assert delta.output_tokens == 0
    end

    test "reads nested params.msg.payload.info.total_token_usage" do
      usage = %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}

      update = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{"params" => %{"msg" => %{"payload" => %{"info" => %{"total_token_usage" => usage}}}}}
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 20
    end

    test "reads atom-key params.msg.payload.info.total_token_usage" do
      usage = %{input_tokens: 6, output_tokens: 1, total_tokens: 7}

      update = %{
        event: :u,
        timestamp: @ts,
        payload: %{params: %{msg: %{payload: %{info: %{total_token_usage: usage}}}}}
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 7
    end

    test "reads params.msg.info.total_token_usage without the extra payload nest" do
      usage = %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}

      update = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{"params" => %{"msg" => %{"info" => %{"total_token_usage" => usage}}}}
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 5
    end

    test "reads params.tokenUsage.total and atom-key tokenUsage.total" do
      string_path = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{"params" => %{"tokenUsage" => %{"total" => %{"prompt_tokens" => 2, "completion_tokens" => 3}}}}
      }

      assert Tokens.extract_token_delta(%{}, string_path).total_tokens == 5

      atom_path = %{
        event: :u,
        timestamp: @ts,
        payload: %{params: %{tokenUsage: %{total: %{promptTokens: 8, completionTokens: 1}}}}
      }

      delta = Tokens.extract_token_delta(%{}, atom_path)
      assert delta.input_tokens == 8
      assert delta.output_tokens == 1
      assert delta.total_tokens == 9
    end

    test "reads turn/completed usage and camelCase keys" do
      update = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{
          "method" => "turn/completed",
          "usage" => %{"inputTokens" => 9, "outputTokens" => 1, "totalTokens" => 10}
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 9
      assert delta.output_tokens == 1
      assert delta.total_tokens == 10
    end

    test "reads turn/completed usage nested under string-key params" do
      update = %{
        event: :u,
        timestamp: @ts,
        payload: %{
          "method" => "turn/completed",
          "params" => %{"usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 3
      assert delta.output_tokens == 2
      assert delta.total_tokens == 5
    end

    test "reads :turn_completed usage nested under atom-key params" do
      update = %{
        event: :u,
        timestamp: @ts,
        payload: %{
          method: :turn_completed,
          params: %{usage: %{input_tokens: 4, output_tokens: 1, total_tokens: 5}}
        }
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 5
    end

    test "string-encoded integers are parsed" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"total_tokens" => "42"}}}
      assert Tokens.extract_token_delta(%{}, update).total_tokens == 42
    end

    test "non-numeric and negative string usage is ignored" do
      update = %{
        event: :u,
        timestamp: @ts,
        usage: %{input_tokens: "nope", output_tokens: "-3", total_tokens: "  "}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 0
      assert delta.output_tokens == 0
      assert delta.total_tokens == 0
      assert delta.input_reported == 0
    end

    test "absent usage yields all-zero delta" do
      update = %{event: :u, timestamp: @ts}
      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 0
      assert delta.output_tokens == 0
      assert delta.total_tokens == 0
    end

    test "reads :turn_completed update[:usage] and fills missing total from input+output" do
      update = %{
        event: :turn_completed,
        timestamp: @ts,
        usage: %{input_tokens: 12, output_tokens: 8}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 12
      assert delta.output_tokens == 8
      assert delta.total_tokens == 20
      assert delta.input_reported == 12
      assert delta.output_reported == 8
      assert delta.total_reported == 20
    end

    test "reads string-key update usage from Agent.Runner turn_completed" do
      update = %{
        :event => :turn_completed,
        :timestamp => @ts,
        "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 4
      assert delta.output_tokens == 6
      assert delta.total_tokens == 10
    end

    test "ignores a non-token update[:usage] map and still reads Claude paths" do
      update = %{
        :event => :u,
        :timestamp => @ts,
        :usage => %{note: "not tokens"},
        "tokenUsage" => %{"total" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 2
    end

    test "thinking_tokens is not added to output or synthesized total" do
      update = %{
        event: :turn_completed,
        timestamp: @ts,
        usage: %{input_tokens: 10, output_tokens: 5, thinking_tokens: 20}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 10
      assert delta.output_tokens == 5
      assert delta.total_tokens == 15
    end

    test "provided total is kept even when thinking_tokens is present" do
      update = %{
        event: :turn_completed,
        timestamp: @ts,
        usage: %{input_tokens: 10, output_tokens: 5, thinking_tokens: 20, total_tokens: 15}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.output_tokens == 5
      assert delta.total_tokens == 15
    end

    test "reads payload usage on a stream_event" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{"usage" => %{"input_tokens" => 3, "output_tokens" => 1}}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 3
      assert delta.output_tokens == 1
      assert delta.total_tokens == 4
    end

    test "reads Codex stream_event payload type turn.completed" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "type" => "turn.completed",
          "usage" => %{
            "input_tokens" => 14_461,
            "cached_input_tokens" => 9984,
            "output_tokens" => 5,
            "reasoning_output_tokens" => 0
          }
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 14_461
      assert delta.output_tokens == 5
      assert delta.total_tokens == 14_466
    end

    test "reads Codex payload type turn/completed" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "type" => "turn/completed",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3}
        }
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 5
    end

    test "reads Antigravity result.usage from a stream_event" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "result",
          "result" => %{
            "status" => "SUCCESS",
            "usage" => %{
              "input_tokens" => 40,
              "output_tokens" => 9,
              "thinking_tokens" => 11,
              "cache_read_tokens" => 2,
              "total_tokens" => 49
            }
          }
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 40
      assert delta.output_tokens == 9
      assert delta.total_tokens == 49
    end

    test "reads Antigravity result usage on the envelope when result.usage is absent" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "result",
          "usage" => %{"input_tokens" => 7, "output_tokens" => 2}
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 7
      assert delta.output_tokens == 2
      assert delta.total_tokens == 9
    end

    test "falls back to envelope usage when Antigravity result is not a map" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "result",
          "result" => "SUCCESS",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
        }
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 6
    end

    test "reads atom-key Codex turn.completed and Antigravity result/step_update payloads" do
      completed = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{type: :turn_completed, usage: %{input_tokens: 6, output_tokens: 1}}
      }

      assert Tokens.extract_token_delta(%{}, completed).total_tokens == 7

      result = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{event: :result, result: %{usage: %{input_tokens: 8, output_tokens: 1}}}
      }

      assert Tokens.extract_token_delta(%{}, result).total_tokens == 9

      stepped = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{event: :step_update, step_update: %{usage: %{input_tokens: 2, output_tokens: 2}}}
      }

      assert Tokens.extract_token_delta(%{}, stepped).total_tokens == 4
    end

    test "ignores step_update when step_update is not a map" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{"event" => "step_update", "step_update" => "active"}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 0
      assert delta.total_tokens == 0
    end

    test "Antigravity step_update.usage increments against last_reported counts" do
      first = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "step_update",
          "step_update" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 20}}
        }
      }

      first_delta = Tokens.extract_token_delta(%{}, first)
      assert first_delta.input_tokens == 100
      assert first_delta.output_tokens == 20
      assert first_delta.total_tokens == 120

      running = %{
        last_reported_input_tokens: first_delta.input_reported,
        last_reported_output_tokens: first_delta.output_reported,
        last_reported_total_tokens: first_delta.total_reported
      }

      second = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "step_update",
          "step_update" => %{"usage" => %{"input_tokens" => 150, "output_tokens" => 35}}
        }
      }

      second_delta = Tokens.extract_token_delta(running, second)
      assert second_delta.input_tokens == 50
      assert second_delta.output_tokens == 15
      assert second_delta.total_tokens == 65
      assert second_delta.input_reported == 150
      assert second_delta.output_reported == 35
      assert second_delta.total_reported == 185
    end

    test "synthesizes total from output-only usage" do
      update = %{event: :turn_completed, timestamp: @ts, usage: %{output_tokens: 11}}
      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 0
      assert delta.output_tokens == 11
      assert delta.total_tokens == 11
    end
  end

  describe "extract_rate_limits/1" do
    test "extracts a direct rate_limits bucket map" do
      rl = %{"limit_id" => "primary", "primary" => %{"remaining" => 10, "limit" => 100}}
      assert Tokens.extract_rate_limits(%{"rate_limits" => rl}) == rl
    end

    test "extracts atom-key :rate_limits on the update" do
      rl = %{"limit_id" => "primary", "primary" => %{"remaining" => 3}}
      assert Tokens.extract_rate_limits(%{rate_limits: rl}) == rl
    end

    test "treats the update itself as a rate-limit map" do
      rl = %{"limit_name" => "x", "secondary" => %{"remaining" => 1}}
      assert Tokens.extract_rate_limits(rl) == rl
    end

    test "finds rate limits nested deep under payload" do
      rl = %{"limit_name" => "x", "credits" => %{"remaining" => 1}}
      assert Tokens.extract_rate_limits(%{"payload" => %{"deep" => rl}}) == rl
    end

    test "finds rate limits inside a list" do
      rl = %{:limit_id => "primary", :secondary => %{remaining: 2}}
      assert Tokens.extract_rate_limits(%{"payload" => [%{"noise" => 1}, rl]}) == rl
    end

    test "finds the first rate-limit map among extra siblings" do
      rl = %{"limit_id" => "credits", "credits" => %{"remaining" => 4}}

      assert Tokens.extract_rate_limits(%{
               "payload" => %{"noise" => 1, "limits" => rl, "more" => "later"}
             }) == rl

      assert Tokens.extract_rate_limits(%{"payload" => ["noise", rl, "later"]}) == rl
    end

    test "returns nil when no rate limits are present or input is not a map" do
      assert Tokens.extract_rate_limits(%{"foo" => "bar"}) == nil
      assert Tokens.extract_rate_limits(:not_a_map) == nil
    end
  end

  # Regression suite for the counter that stayed at zero through a whole run.
  # The shapes here are copied from a real ~/.cymphony/log transcript.
  describe "extract_token_delta/2 — Claude stream-json per-message usage" do
    test "reads usage nested under message, which the envelope does not carry" do
      update =
        assistant_event(%{
          "input_tokens" => 2,
          "cache_creation_input_tokens" => 2320,
          "cache_read_input_tokens" => 56_904,
          "output_tokens" => 16
        })

      delta = Tokens.extract_token_delta(%{}, update)

      # 2 + 2320: fresh input plus the cache *write*. The bare input_tokens
      # field alone is 2, and the 56904-token cache read is excluded.
      assert delta.input_tokens == 2322
      assert delta.output_tokens == 16
      assert delta.total_tokens == 2338
    end

    test "cache reads are excluded so a long session is not counted once per turn" do
      # The prefix is re-reported in full on every turn; summing it made a
      # two-hour run read like months of usage.
      turn = fn read ->
        assistant_event(%{
          "input_tokens" => 2,
          "cache_creation_input_tokens" => 100,
          "cache_read_input_tokens" => read,
          "output_tokens" => 3
        })
      end

      entry = %{}

      {total, _entry} =
        Enum.reduce([10_000, 35_000, 50_000, 56_904], {0, entry}, fn read, {sum, acc} ->
          delta = Tokens.extract_token_delta(acc, turn.(read))

          {sum + delta.input_tokens,
           %{
             last_reported_input_tokens: delta.input_reported,
             last_reported_output_tokens: delta.output_reported,
             last_reported_total_tokens: delta.total_reported
           }}
        end)

      # 4 turns x (2 + 100). Not 151_904 + 408.
      assert total == 408
    end

    test "sums successive messages instead of diffing them" do
      # The bug: per-message input_tokens sits at 2 for every turn, so the
      # monotonic absolute-diff rule scored each one as zero.
      first = assistant_event(%{"input_tokens" => 2, "output_tokens" => 10})
      second = assistant_event(%{"input_tokens" => 2, "output_tokens" => 7})

      d1 = Tokens.extract_token_delta(%{}, first)
      assert d1.input_tokens == 2
      assert d1.output_tokens == 10

      entry = %{
        last_reported_input_tokens: d1.input_reported,
        last_reported_output_tokens: d1.output_reported,
        last_reported_total_tokens: d1.total_reported
      }

      d2 = Tokens.extract_token_delta(entry, second)
      assert d2.input_tokens == 2
      assert d2.output_tokens == 7
    end

    test "carries a running sum in `reported` so a later result event cannot double-count" do
      turn = assistant_event(%{"input_tokens" => 100, "output_tokens" => 20})
      d1 = Tokens.extract_token_delta(%{}, turn)

      entry = %{
        last_reported_input_tokens: d1.input_reported,
        last_reported_output_tokens: d1.output_reported,
        last_reported_total_tokens: d1.total_reported
      }

      # The CLI's final cumulative frame: 150 in / 25 out for the session.
      result = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{"type" => "result", "usage" => %{"input_tokens" => 150, "output_tokens" => 25}}
      }

      d2 = Tokens.extract_token_delta(entry, result)

      # Only the correction lands, not the whole session a second time.
      assert d2.input_tokens == 50
      assert d2.output_tokens == 5
      assert d1.input_tokens + d2.input_tokens == 150
      assert d1.output_tokens + d2.output_tokens == 25
    end

    test "a message with no usage contributes nothing and preserves the running sum" do
      entry = %{last_reported_input_tokens: 500, last_reported_output_tokens: 30}

      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{"type" => "assistant", "message" => %{"role" => "assistant"}}
      }

      delta = Tokens.extract_token_delta(entry, update)

      assert delta.input_tokens == 0
      assert delta.output_tokens == 0
      assert delta.input_reported == 500
      assert delta.output_reported == 30
    end

    test "an envelope-level usage still wins over message.usage" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "type" => "assistant",
          "usage" => %{"input_tokens" => 900, "output_tokens" => 90},
          "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}
        }
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 900
      assert delta.output_tokens == 90
    end

    test "cache writes count toward input on an absolute result frame too" do
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 5,
            "cache_creation_input_tokens" => 100,
            "cache_read_input_tokens" => 1000,
            "output_tokens" => 7
          }
        }
      }

      assert Tokens.extract_token_delta(%{}, update).input_tokens == 105
    end

    test "Antigravity cache_read_tokens is not folded into input" do
      # Its result usage already reports an inclusive input_tokens, so adding
      # the cache field would double-count.
      update = %{
        event: :stream_event,
        timestamp: @ts,
        payload: %{
          "event" => "result",
          "result" => %{
            "usage" => %{
              "input_tokens" => 40,
              "output_tokens" => 9,
              "cache_read_tokens" => 2,
              "total_tokens" => 49
            }
          }
        }
      }

      assert Tokens.extract_token_delta(%{}, update).input_tokens == 40
    end
  end

  # A Claude `stream-json` assistant event, shaped as the CLI emits it.
  defp assistant_event(usage) do
    %{
      event: :stream_event,
      timestamp: @ts,
      payload: %{
        "type" => "assistant",
        "message" => %{
          "model" => "claude-opus-5",
          "type" => "message",
          "role" => "assistant",
          "usage" => usage
        }
      }
    }
  end
end
