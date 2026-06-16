# In-flight-turn awareness for subagent control: stop flagging healthy long turns as stale

## Context

The subagent control system (`src/runs/shared/subagent-control.ts`,
`deriveActivityState`) emits a `needs_attention` notice - the rectangular ASCII
box reading `<agent> needs attention (no observed activity for Xs)` - whenever a
running child crosses `needsAttentionAfterMs` (default 60_000) with no observed
activity. The notice body suggests interrupting the run.

Observed in practice with the `spec-council` flow from `pi-superpowers`: the
chair (`spec-council-synthesizer`) is the #1 offender (180 notice occurrences
across the user's sessions; next are `spec-council-member`, `code-reviewer`,
`implementer`, `worker`). One real chair turn ran 506s (8.4 min) before the
notice fired. The main loop almost always recovers because the chair still writes
its output, and the model self-diagnoses the ping as stale - but that is
model-dependent luck, the false positives cause alarm fatigue on the same channel
that should surface genuine stalls, and the notice literally instructs
`subagent({action:"interrupt"})`, which would corrupt a healthy run if acted on.

### Root cause (verified against code + live `pi --mode json -p` probes)

- The child runs as `pi --mode json -p`. It emits `turn_start`, `message_start`,
  `message_update` (per streamed token/delta), `message_end`, `turn_end`,
  plus `tool_execution_start/end` and `tool_result_end`.
- **Both** execution paths already advance their activity timestamp on *every*
  parsed child line:
  - Foreground `processLine` (`src/runs/foreground/execution.ts`) sets
    `progress.lastActivityAt = now` on any JSON line.
  - Background `updateStepFromChildEvent` (`src/runs/background/subagent-runner.ts`)
    sets `step.lastActivityAt = now` unconditionally at the end, for every event;
    the watchdog reads `stepOutputActivityAt(index)` = `max(step.lastActivityAt,
    output-N.log mtime)`.
  So "surface `message_start` and advance the clock on it" is **already**
  happening. A one-shot turn-start ping would not help: the clock just restarts
  and re-trips at the next `+needsAttentionAfterMs`.
- Probe result: for the models in use, **text streams as `message_update`
  (`assistantMessageEvent.type` = `text_*`) but thinking does NOT stream** (no
  `thinking_delta`). So the only event-free window is `message_start` -> first
  `text_delta`: the entire reasoning/time-to-first-token (TTFT) phase, which emits
  zero child lines. On a large chair context (full spec + N critiques) that
  silent window is the measured 506s. `deriveActivityState` sees
  `now - lastActivityAt > 60s` and fires `needs_attention`.

The detector conflates "no event boundary crossed" with "stuck." For a
single-turn, tool-light, reasoning-heavy agent the silent TTFT window is
*unfalsifiable* as activity - it can never produce a mid-turn signal during
thinking, so it will always trip the 60s threshold if reasoning is slow.

The parent does **not** currently track whether a turn is open. `ChildEvent`
(`src/runs/background/subagent-runner.ts`) is a loose
`{ type?: string; message?: ...; toolName?: ...; args?: ... }`, and the parent
only branches on `tool_execution_start/end`, `tool_result_end`, `message_end`.
`message_start`/`turn_start`/`message_update` fall through to the generic
timestamp bump - nothing records "a turn is in flight."

## Decisions (locked with user)

- **Behavior (option A + a bound).** While a turn is in flight (we have seen a
  turn open and not yet its close), the idle timer no longer escalates to
  `needs_attention`; it downgrades to the existing, calm `active_long_running`
  state. `needs_attention` from the idle path then fires only when a turn is
  **not** in flight (genuinely idle, no open turn).
- **Zero-output is bounded, not unbounded.** An in-flight turn that produces
  *nothing observable* (no `message_update`, no tool event, no close) cannot sit
  calm forever. A silence ceiling caps the suppression; past it, the detector
  escalates back to `needs_attention`. The agent must produce, stream, or close
  within a bounded cycle.
- **Bound keyed on silence-since-last-productive-signal**, not total turn
  duration. A turn that keeps streaming `message_update`s is demonstrably alive
  and stays calm indefinitely; only true silence is bounded. (Chosen over a
  total-in-flight-duration cap, which would wrongly trip a legitimately long
  *streaming* turn.) The baseline is the last productive signal, which may
  predate the current turn (e.g. a tool that completed earlier in the run).
  This is deliberate: agents that emit frequent tool/stream events always have a
  recent `lastProductiveSignalAt`, so the only case where pre-turn time counts
  against the ceiling is a genuinely production-silent agent - exactly the case
  we want bounded. We do **not** add a separate `turnOpenedAt` baseline; the
  ceiling intentionally measures time since the last observable production, not
  time since the turn opened.
- **Ceiling default 600_000 ms (10 min).** Clears the observed 506s legit TTFT
  with headroom. Configurable and per-call overridable like the other control
  fields. (2 min was rejected: it re-trips at 120s, reintroducing the exact false
  positive on every slow chair turn.)
- **Turn-open is not a productive signal.** `message_start`/`turn_start` open the
  turn but must not refresh the silence clock - otherwise turn-open alone resets
  the bound and we suppress forever, defeating the zero-output cap.
- **Reuse the existing `active_long_running` machinery** - no new event type, no
  new notice copy, no new channel. The change is purely *which* state
  `deriveActivityState` returns during a silent in-flight window.

## Design

### 1. Turn-lifecycle + productive-signal tracking (both paths)

**Event-type verification.** Confirmed via live `pi --mode json -p` probe: the
child emits `turn_start`, `message_start`, `message_update` (per streamed
token/delta), `message_end`, and `turn_end`, plus `tool_execution_start/end` and
`tool_result_end`. The parent currently parses only `tool_execution_start/end`,
`tool_result_end`, and `message_end` (`processLine`,
`updateStepFromChildEvent`); `turn_start`/`message_start`/`message_update`/
`turn_end` are newly matched by this change. If a provider omits
`turn_start`/`turn_end`, the implementation derives turn-open state solely from
`message_start`/`message_end` - `turn_*` is only a belt-and-suspenders close.

Track two new fields, stored as follows:

- Foreground: add `turnOpen?: boolean` and `lastProductiveSignalAt?: number` to
  `AgentProgress` (`src/shared/types.ts:197`).
- Background: add the same two fields to the per-step status object
  (`RunnerStatusStep`, the element type of `statusPayload.steps`).

These fields are **internal lifecycle state**. The background fields ride in the
step object that already persists to `status.json`, so they must be initialized
to `turnOpen = false` / `lastProductiveSignalAt = undefined` at run start and
**reset on every step (re)start, retry, and resume** alongside the existing
`resetStepLiveDetail` / step-start reset logic, so a stale open-turn flag from a
prior attempt cannot leak into a later one. Foreground fields reset on run start.

Event handling (added to foreground `processLine` and background
`updateStepFromChildEvent`; `ChildEvent.type` is already `string`, so matching
the new literals needs no type change, and we do not inspect the delta subtype -
any `message_update` counts as production; guard against `undefined` `type`
exactly as the existing branches do):

| Child event | `turnOpen` | `lastProductiveSignalAt` |
|---|---|---|
| `message_start` / `turn_start` | set `true` | unchanged |
| `message_update` | unchanged | `= now` |
| `tool_execution_start` / `tool_execution_end` / `tool_result_end` | unchanged | `= now` |
| `message_end`, pending tool call (`stopReason !== "stop"` or `hasToolCall`) | unchanged | `= now` |
| `message_end`, no pending tool call (`stopReason === "stop" && !hasToolCall`) | set `false` | `= now` |
| `turn_end` | set `false` | `= now` |

The `message_end` close rule reuses the `stopReason` / `hasToolCall` read the
foreground path already performs (`execution.ts:501-504`). A turn may contain
tool-use/tool-result cycles between assistant messages: an intermediate
`message_end` that carries a tool call must **not** close the turn, or the
following tool-execution gap would fall back to the idle `needs_attention` path.
Those intervening tool events are themselves productive and keep the turn calm.
The only event-free phase is `message_start` -> first `message_update`, which is
precisely the silent window this spec targets. Setting `turnOpen = false` is
idempotent; whichever of the final `message_end` / `turn_end` arrives first
closes, and the other is a no-op.

The existing per-event activity-timestamp bump is retained unchanged; the new
fields are additive.

### 2. `deriveActivityState` new contract

Extend the existing input object - `{ config, startedAt, lastActivityAt?, now? }`
- with two **optional** fields `inFlightTurn?: boolean` (default `false`) and
`lastProductiveSignalAt?: number` (default `undefined`). Callers that pass
neither get today's behavior unchanged, so the signature change is
non-breaking for any other caller. Config gains `inFlightSilenceCeilingMs`
(default 600_000). Logic:

```
if (!enabled) return undefined
ageMs = now - (lastActivityAt ?? startedAt)
if (ageMs <= needsAttentionAfterMs) return undefined          // not idle yet
if (inFlightTurn) {
  silenceMs = now - (lastProductiveSignalAt ?? startedAt)
  return silenceMs > inFlightSilenceCeilingMs
    ? "needs_attention"      // zero-output bound trips (default 10 min)
    : "active_long_running"  // calm: model is thinking or streaming
}
return "needs_attention"                                       // genuinely idle, no open turn
```

- A streaming turn refreshes `lastProductiveSignalAt` on every `message_update`,
  so `silenceMs` stays small and it never trips - calm for its whole run.
- A silent thinker holds `lastProductiveSignalAt` at the pre-turn value; once
  `ageMs > needsAttentionAfterMs` it reports `active_long_running` (calm), and
  only after `silenceMs > inFlightSilenceCeilingMs` does it escalate to
  `needs_attention` - the bounded zero-output cycle the user required.

### 2a. Caller-side handling (both paths)

Returning `active_long_running` from `deriveActivityState` is **not** sufficient
on its own: both callers today branch only on `idleState === "needs_attention"`
(foreground `execution.ts:398`, background `subagent-runner.ts:1319`) and the
calm `active_long_running` notice is driven by a *separate* code path
(foreground active-notice closure at `execution.ts:366-373`, background
`maybeEmitActiveLongRunning` at `subagent-runner.ts:1168`). A bare return value
would be silently dropped. Required caller deltas:

- **Suppression is automatic**: because `deriveActivityState` now returns
  `active_long_running` (not `needs_attention`) during a silent in-flight window
  under the ceiling, the existing `if (idleState === "needs_attention")` branch
  simply does not fire - no `emitNeedsAttention`. This is the core fix.
- **Calm notice**: add an `else if (idleState === "active_long_running")` branch
  in both callers that routes into the existing active-long-running emission
  (foreground: set `progress.activityState = "active_long_running"` and reuse the
  active-notice closure; background: call `maybeEmitActiveLongRunning`). It must
  honor the existing dedup guards (`activeLongRunningNotified` /
  `step.activityState`) so the calm notice fires at most once per run/step, and
  reuse the existing `ControlEvent` `type: "active_long_running"` - no new event
  type or reason string.

The existing token/turn-based `active_long_running` triggers
(`nextLongRunningTrigger`, `maybeEmitActiveLongRunning`) are otherwise
unaffected; this change only adds an in-flight downgrade to the *idle* branch of
`deriveActivityState` plus the caller branch that consumes it. `tool_failures`
and completion-guard escalations are out of this branch and unchanged.

### 3. Config plumbing

- Add `inFlightSilenceCeilingMs?: number` to `ControlConfig` and
  `ResolvedControlConfig` (`src/shared/types.ts`).
- `DEFAULT_CONTROL_CONFIG.inFlightSilenceCeilingMs = 600_000`.
- Parse in `resolveControlConfig` via the existing positive-int parser, merging a
  per-call `control` override over the global config exactly like
  `needsAttentionAfterMs` and `activeNoticeAfterMs`.
- Add the field to the `ControlOverrides` TypeBox schema
  (`src/extension/schemas.ts:221`) as
  `inFlightSilenceCeilingMs: Type.Optional(Type.Integer({ minimum: 1, description: ... }))`,
  matching the sibling fields. Without this, a per-call override is rejected/
  dropped at tool-call validation before `resolveControlConfig` ever sees it.
- Document it in `README.md` (control section) alongside the other control knobs:
  one row stating it bounds how long a silent in-flight turn stays calm before
  re-escalating to `needs_attention` (default 600000 ms / 10 min).

### 4. Notice emission

No new event type, notice copy, channel, or dedup key. The in-flight calm window
flows through the existing `active_long_running` emission path. The only
behavioral delta: during a silent in-flight window under the ceiling,
`deriveActivityState` returns `active_long_running` where it previously returned
`needs_attention`.

## Testing

- **Unit (`deriveActivityState`)** - extend `test/unit/subagent-control.test.ts`
  (which already uses small ms thresholds, e.g. `needsAttentionAfterMs: 300`) with
  the truth table:
  - `ageMs <= needsAttentionAfterMs` -> `undefined`.
  - in-flight, `silenceMs <= ceiling` -> `active_long_running`.
  - in-flight, `silenceMs > ceiling` -> `needs_attention`.
  - not in-flight, idle past threshold -> `needs_attention`.
  - `enabled: false` -> `undefined`.
- **Unit (lifecycle)** - extract a pure helper
  `applyChildEventToLifecycle(state, event) -> { turnOpen, lastProductiveSignalAt }`
  (shared by both `processLine` and `updateStepFromChildEvent`) so the reducer is
  unit-testable without a child process: assert `message_start` sets `turnOpen`
  without moving `lastProductiveSignalAt`; `message_update` and tool events move
  it; a final `message_end` (`stopReason "stop"`, no tool call) and `turn_end`
  clear `turnOpen`; an intermediate `message_end` with a tool call leaves
  `turnOpen` set.
- **Unit (config)** - `resolveControlConfig` applies the default 600_000 and a
  per-call `inFlightSilenceCeilingMs` override; `ControlOverrides` schema accepts
  the field.
- **Integration** - foreground is covered end-to-end (below). The background
  runner's wiring is covered by the lifecycle/composition unit test plus the
  existing async/parallel/status regression suites, **not** a dedicated
  end-to-end background assertion: `updateRunnerActivityState` is a private
  closure inside the detached runner and a time-based spawn assertion is flaky.
  The reducer + `deriveActivityState` are path-agnostic, so the unit coverage
  exercises the identical logic both paths invoke. Foreground end-to-end:
  drive the watchdog with small per-call overrides
  (`control: { needsAttentionAfterMs: 100, inFlightSilenceCeilingMs: 500 }`) to
  avoid real-time waits: a child that emits `message_start` then stays silent
  past `needsAttentionAfterMs` but under the ceiling yields `active_long_running`
  (not `needs_attention`) in foreground and background; silence past the ceiling
  yields `needs_attention`.
- Run `env -u PI_CODING_AGENT_DIR npm run test:unit` and
  `npm run test:integration` per `AGENTS.md`.

## Out of scope

- Parsing pi core `auto_retry_*` events. The silence ceiling is the backstop for
  a truly wedged request; modeling retry/network state is a separate concern.
- Distinguishing "model thinking" from "network stall" during the silent window.
  Both are bounded identically by `inFlightSilenceCeilingMs` by design - the
  parent cannot tell them apart from the event stream, and does not need to.
- Changing `needsAttentionAfterMs` / `activeNoticeAfterMs` defaults or the
  notice rendering, channels, or copy.
- Any change to the `pi-superpowers` council skill. The earlier per-call
  `control` override (skill-side) remains a valid immediate mitigation but is
  independent of this engine fix, which corrects the behavior for every agent.
