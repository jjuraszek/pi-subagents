# In-flight-turn awareness for subagent control - Implementation Plan

> **REQUIRED SUB-SKILL:** Use the subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Stop `deriveActivityState` from flagging healthy long single-turn agents as `needs_attention` during a silent in-flight turn, while keeping a 10-minute zero-output ceiling so a truly wedged turn still escalates.

**Architecture:** Add turn-lifecycle tracking (`turnOpen`, `lastProductiveSignalAt`) to both execution paths via a shared pure reducer in `subagent-control.ts`. `deriveActivityState` gains two optional inputs and a `inFlightSilenceCeilingMs` config field: while a turn is in flight and silence is under the ceiling it returns `active_long_running` (calm) instead of `needs_attention`. Both watchdogs already route a non-`needs_attention` idle result into the existing calm-notice path, so no new event type, notice copy, or emission branch is required - only threading the two new inputs and updating the lifecycle fields per child event.

**Tech Stack:** TypeScript (type-stripped at test time, no `tsc`), node `--test`, TypeBox schemas.

**Spec:** `doc/specs/2026-06-16-in-flight-turn-activity-state.md`

---

## Reconciliation note (plan-time, grounded in caller code)

The spec's section 2a proposes adding an explicit `else if (idleState === "active_long_running")` emission branch to both callers. Reading the actual callers shows that is unnecessary and would be harmful:

- Foreground `updateActivityState` (`src/runs/foreground/execution.ts:390-410`): branches `if (idleState === "needs_attention") {...} ` then **falls through** to `nextLongRunningTrigger` + `emitActiveLongRunning`. A returned `active_long_running` simply skips the `needs_attention` branch; the calm notice continues to fire on its own `activeNoticeAfterMs` (240s) schedule via `emitActiveLongRunning` (guarded by `activeLongRunningNotified`).
- Background `updateRunnerActivityState` (`src/runs/background/subagent-runner.ts:1300-1336`): `if (idleState === "needs_attention") {...} else if (maybeEmitActiveLongRunning(index, now)) {...}`. A returned `active_long_running` falls into the existing `else if`, which is gated by `nextLongRunningTrigger` + `activeLongRunningSteps` dedup.

Adding a forced emission branch would create a **new** calm notice at `needsAttentionAfterMs` (60s) instead of the intended `activeNoticeAfterMs` (240s), contradicting the spec's "no new threshold/copy" decision. **Therefore: the suppression is automatic** - the only caller change is passing `inFlightTurn` + `lastProductiveSignalAt` into the `deriveActivityState` call. This is the faithful implementation of the spec's intent (reuse existing machinery, no new event type).

The spec's "Integration (both paths)" item is implemented as: one foreground end-to-end test via the `mockPi` harness, plus a deterministic **composition** unit test for the background path (construct a `RunnerStatusStep`, apply the reducer to a `message_start` event, assert `deriveActivityState` over the resulting fields returns `active_long_running`). `updateRunnerActivityState` is a private closure inside the detached runner; spawning it for a time-based assertion is flaky, and the composition test covers the exact logic the watchdog performs.

## Files

**Modify:**
- `src/shared/types.ts` (add `inFlightSilenceCeilingMs` to `ControlConfig` ~L102 and `ResolvedControlConfig` ~L112; add `turnOpen?: boolean` + `lastProductiveSignalAt?: number` to `AgentProgress` ~L197)
- `src/extension/schemas.ts` (add `inFlightSilenceCeilingMs` to `ControlOverrides` ~L221-224)
- `src/runs/shared/subagent-control.ts` (`DEFAULT_CONTROL_CONFIG` ~L14, `resolveControlConfig` ~L37, `deriveActivityState` ~L75; add exported `applyChildEventToLifecycle`)
- `src/runs/foreground/execution.ts` (init `progress` fields ~L214; wire reducer into `processLine` ~L437; thread inputs in `updateActivityState` ~L391-397)
- `src/runs/background/subagent-runner.ts` (extend `RunnerStatusStep` ~L828; reset in `resetStepLiveDetail` ~L174; wire reducer in `updateStepFromChildEvent` ~L1207-1296; thread inputs in `updateRunnerActivityState` ~L1305-1316; init fields in initial + dynamic step construction ~L974, ~L1496)
- `test/support/helpers.ts` (add `events.messageStart` / `events.messageUpdate` ~L154)
- `README.md` (control config section: document `inFlightSilenceCeilingMs`)

**Create:**
- `test/integration/foreground-in-flight-control.test.ts`

**Test (modify):**
- `test/unit/subagent-control.test.ts`

---

## Wave 1 - Contracts (types, schema, docs)

Parallel-safe: Tasks 1-3 own disjoint files (`src/shared/types.ts`, `src/extension/schemas.ts`, `README.md`); all are pure declaration/doc edits with no shared runtime resource.

### Task 1: Config + progress type fields

**TDD scenario:** Trivial type additions - no standalone test; consumed and verified by Wave 2/3 tests.

**Files:**
- Modify: `src/shared/types.ts`

- [ ] **Step 1: Add the config field to both interfaces**

  In `ControlConfig` (after `activeNoticeAfterMs?: number;`):
  ```typescript
  	inFlightSilenceCeilingMs?: number;
  ```
  In `ResolvedControlConfig` (after `activeNoticeAfterMs: number;`):
  ```typescript
  	inFlightSilenceCeilingMs: number;
  ```

- [ ] **Step 2: Add lifecycle fields to `AgentProgress`**

  In `interface AgentProgress` (after `lastActivityAt?: number;`):
  ```typescript
  	turnOpen?: boolean;
  	lastProductiveSignalAt?: number;
  ```

- [ ] **Step 3: Confirm type-strip parses**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/unit/subagent-control.test.ts 2>&1 | tail -5`
  Expected: existing tests still pass (no type errors from the new fields).

- [ ] **Step 4: Commit**

  ```bash
  git add src/shared/types.ts
  git commit -m "Add inFlightSilenceCeilingMs + turn-lifecycle progress fields"
  ```

### Task 2: ControlOverrides schema field

**TDD scenario:** Modifying tested code - `test/unit/schemas.test.ts` covers the schema; run it after.

**Files:**
- Modify: `src/extension/schemas.ts:221-224`

- [ ] **Step 1: Add the field to the `ControlOverrides` TypeBox object**

  After the `activeNoticeAfterMs` line:
  ```typescript
  	inFlightSilenceCeilingMs: Type.Optional(Type.Integer({ minimum: 1, description: "How long a silent in-flight turn stays calm (active_long_running) before re-escalating to needs_attention (default: 600000)" })),
  ```

- [ ] **Step 2: Run schema unit tests**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/unit/schemas.test.ts 2>&1 | tail -10`
  Expected: PASS (no regression; field is optional so existing fixtures validate).

- [ ] **Step 3: Commit**

  ```bash
  git add src/extension/schemas.ts
  git commit -m "Expose inFlightSilenceCeilingMs in control override schema"
  ```

### Task 3: README control-config doc

**TDD scenario:** Doc-only - no test.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the control-config documentation**

  Run: `rg -n "needsAttentionAfterMs|activeNoticeAfterMs" README.md`
  Find the section/table listing control knobs.

- [ ] **Step 2: Add an entry for `inFlightSilenceCeilingMs`**

  Match the surrounding format (table row or bullet). Content:
  > `inFlightSilenceCeilingMs` (default `600000`) - while an assistant turn is in flight, a silent stretch under this bound is reported as the calm `active_long_running` state instead of `needs_attention`; silence past it re-escalates to `needs_attention`. Bounds zero-output turns without flagging healthy long thinking/streaming.

- [ ] **Step 3: Commit**

  ```bash
  git add README.md
  git commit -m "Document inFlightSilenceCeilingMs control knob"
  ```

---

## Wave 2 - Core logic + unit tests

Depends on Wave 1 (Task 1's `ResolvedControlConfig.inFlightSilenceCeilingMs` and `AgentProgress` fields). Single task (sequential).

### Task 4: deriveActivityState in-flight logic + lifecycle reducer + config

**TDD scenario:** New behaviour - full TDD cycle. `test/unit/subagent-control.test.ts` already exists (uses small ms thresholds like `needsAttentionAfterMs: 300`).

**Files:**
- Modify: `src/runs/shared/subagent-control.ts`
- Test: `test/unit/subagent-control.test.ts`

- [ ] **Step 1: Write the failing tests**

  Add to `test/unit/subagent-control.test.ts`. Import `applyChildEventToLifecycle` alongside the existing imports.

  ```typescript
  const ceilingConfig = resolveControlConfig(undefined, {
  	needsAttentionAfterMs: 300,
  	inFlightSilenceCeilingMs: 1_000,
  });

  describe("in-flight turn activity state", () => {
  	it("defaults inFlightSilenceCeilingMs to 600000 and parses overrides", () => {
  		assert.equal(resolveControlConfig(undefined, undefined).inFlightSilenceCeilingMs, 600_000);
  		assert.equal(resolveControlConfig(undefined, { inFlightSilenceCeilingMs: 1_000 }).inFlightSilenceCeilingMs, 1_000);
  		assert.equal(resolveControlConfig(undefined, { inFlightSilenceCeilingMs: 0 }).inFlightSilenceCeilingMs, 600_000);
  	});

  	it("downgrades a silent in-flight turn under the ceiling to active_long_running", () => {
  		assert.equal(deriveActivityState({
  			config: ceilingConfig, startedAt: 0, lastActivityAt: 0, now: 400,
  			inFlightTurn: true, lastProductiveSignalAt: 0,
  		}), "active_long_running");
  	});

  	it("escalates a silent in-flight turn past the ceiling to needs_attention", () => {
  		assert.equal(deriveActivityState({
  			config: ceilingConfig, startedAt: 0, lastActivityAt: 0, now: 1_200,
  			inFlightTurn: true, lastProductiveSignalAt: 0,
  		}), "needs_attention");
  	});

  	it("keeps a streaming turn calm: a recent productive signal resets the silence clock", () => {
  		assert.equal(deriveActivityState({
  			config: ceilingConfig, startedAt: 0, lastActivityAt: 1_150, now: 1_200,
  			inFlightTurn: true, lastProductiveSignalAt: 1_150,
  		}), undefined);
  	});

  	it("flags genuine idle (no turn open) as needs_attention", () => {
  		assert.equal(deriveActivityState({
  			config: ceilingConfig, startedAt: 0, lastActivityAt: 0, now: 400,
  			inFlightTurn: false,
  		}), "needs_attention");
  	});

  	it("is backward compatible when in-flight inputs are omitted", () => {
  		assert.equal(deriveActivityState({ config: ceilingConfig, startedAt: 0, lastActivityAt: 0, now: 400 }), "needs_attention");
  	});

  	it("reduces child events into turn-lifecycle state", () => {
  		const opened = applyChildEventToLifecycle({ turnOpen: false }, { type: "message_start" }, 100);
  		assert.equal(opened.turnOpen, true);
  		assert.equal(opened.lastProductiveSignalAt, undefined);

  		const streamed = applyChildEventToLifecycle(opened, { type: "message_update" }, 200);
  		assert.equal(streamed.turnOpen, true);
  		assert.equal(streamed.lastProductiveSignalAt, 200);

  		const intermediate = applyChildEventToLifecycle(streamed, { type: "message_end", hasToolCall: true }, 300);
  		assert.equal(intermediate.turnOpen, true, "tool-call message_end must not close the turn");
  		assert.equal(intermediate.lastProductiveSignalAt, 300);

  		const closed = applyChildEventToLifecycle(intermediate, { type: "message_end", hasToolCall: false }, 400);
  		assert.equal(closed.turnOpen, false);

  		const turnEnded = applyChildEventToLifecycle({ turnOpen: true }, { type: "turn_end" }, 500);
  		assert.equal(turnEnded.turnOpen, false);
  		assert.equal(turnEnded.lastProductiveSignalAt, 500);
  	});

  	it("composes the way the background watchdog does (in-flight step stays calm)", () => {
  		const state = applyChildEventToLifecycle({ turnOpen: false, lastProductiveSignalAt: 0 }, { type: "message_start" }, 0);
  		assert.equal(deriveActivityState({
  			config: ceilingConfig, startedAt: 0, lastActivityAt: 0, now: 400,
  			inFlightTurn: state.turnOpen, lastProductiveSignalAt: state.lastProductiveSignalAt,
  		}), "active_long_running");
  	});
  });
  ```

- [ ] **Step 2: Run, confirm failure**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/unit/subagent-control.test.ts 2>&1 | tail -15`
  Expected: FAIL - `applyChildEventToLifecycle` is not exported; in-flight branches not implemented.

- [ ] **Step 3: Implement `inFlightSilenceCeilingMs` in config**

  In `DEFAULT_CONTROL_CONFIG` (after `activeNoticeAfterMs: 240_000,`):
  ```typescript
  	inFlightSilenceCeilingMs: 600_000,
  ```
  In `resolveControlConfig`, after the `activeNoticeAfterMs` const:
  ```typescript
  	const inFlightSilenceCeilingMs = parsePositiveInt(override?.inFlightSilenceCeilingMs)
  		?? parsePositiveInt(globalConfig?.inFlightSilenceCeilingMs)
  		?? DEFAULT_CONTROL_CONFIG.inFlightSilenceCeilingMs;
  ```
  Add `inFlightSilenceCeilingMs,` to the returned object.

- [ ] **Step 4: Implement the lifecycle reducer (exported, pure)**

  Add to `subagent-control.ts`:
  ```typescript
  export interface TurnLifecycleState {
  	turnOpen?: boolean;
  	lastProductiveSignalAt?: number;
  }

  export function applyChildEventToLifecycle(
  	state: TurnLifecycleState,
  	event: { type?: string; hasToolCall?: boolean },
  	now: number,
  ): TurnLifecycleState {
  	switch (event.type) {
  		case "turn_start":
  		case "message_start":
  			return { turnOpen: true, lastProductiveSignalAt: state.lastProductiveSignalAt };
  		case "message_update":
  		case "tool_execution_start":
  		case "tool_execution_end":
  		case "tool_result_end":
  			return { turnOpen: state.turnOpen, lastProductiveSignalAt: now };
  		case "message_end":
  			return { turnOpen: event.hasToolCall ? state.turnOpen : false, lastProductiveSignalAt: now };
  		case "turn_end":
  			return { turnOpen: false, lastProductiveSignalAt: now };
  		default:
  			return state;
  	}
  }
  ```

- [ ] **Step 5: Implement in-flight logic in `deriveActivityState`**

  Replace the function with:
  ```typescript
  export function deriveActivityState(input: {
  	config: ResolvedControlConfig;
  	startedAt: number;
  	lastActivityAt?: number;
  	now?: number;
  	inFlightTurn?: boolean;
  	lastProductiveSignalAt?: number;
  }): ActivityState | undefined {
  	if (!input.config.enabled) return undefined;
  	const now = input.now ?? Date.now();
  	const lastActivity = input.lastActivityAt ?? input.startedAt;
  	const ageMs = Math.max(0, now - lastActivity);
  	if (ageMs <= input.config.needsAttentionAfterMs) return undefined;
  	if (input.inFlightTurn) {
  		const silenceMs = Math.max(0, now - (input.lastProductiveSignalAt ?? input.startedAt));
  		return silenceMs > input.config.inFlightSilenceCeilingMs ? "needs_attention" : "active_long_running";
  	}
  	return "needs_attention";
  }
  ```

- [ ] **Step 6: Run, confirm pass**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/unit/subagent-control.test.ts 2>&1 | tail -15`
  Expected: PASS (all new + existing cases).

- [ ] **Step 7: Commit**

  ```bash
  git add src/runs/shared/subagent-control.ts test/unit/subagent-control.test.ts
  git commit -m "Add in-flight-turn awareness to deriveActivityState + lifecycle reducer"
  ```

---

## Wave 3 - Wire both execution paths

Depends on Wave 2 (`applyChildEventToLifecycle`, `deriveActivityState` new inputs). Parallel-safe: Task 5 owns `src/runs/foreground/execution.ts` + `test/integration/foreground-in-flight-control.test.ts` + `test/support/helpers.ts`; Task 6 owns `src/runs/background/subagent-runner.ts`. Disjoint files; the integration test in Task 5 spawns the mock pi CLI in its own `mkdtemp` dir (no shared port/DB/fixture with Task 6, which adds no spawn test).

### Task 5: Foreground wiring + integration test

**TDD scenario:** New behaviour - full TDD cycle via the `mockPi` harness.

**Files:**
- Modify: `src/runs/foreground/execution.ts`
- Modify: `test/support/helpers.ts`
- Test (create): `test/integration/foreground-in-flight-control.test.ts`

- [ ] **Step 1: Add mock event helpers**

  In `test/support/helpers.ts`, inside the `events` object (after `assistantMessage`):
  ```typescript
  	messageStart(): object {
  		return { type: "message_start" };
  	},

  	messageUpdate(text = "partial"): object {
  		return { type: "message_update", assistantMessageEvent: { type: "text_delta", text } };
  	},
  ```

- [ ] **Step 2: Write the failing integration test**

  Create `test/integration/foreground-in-flight-control.test.ts`. Model imports/harness on `test/integration/single-execution.test.ts` (`createMockPi`, `makeAgentConfigs`, `runSync`, `events`, `RunSyncResult`, `beforeEach`/`afterEach` install/uninstall). Two cases:

  ```typescript
  it("treats a silent in-flight turn under the ceiling as active_long_running, not needs_attention", async () => {
  	mockPi.onCall({
  		steps: [
  			{ jsonl: [events.messageStart()] },
  			{ delay: 1_300, jsonl: [events.assistantMessage("done")] },
  		],
  	});
  	const agents = makeAgentConfigs(["echo"]);
  	const controlEvents: NonNullable<RunSyncResult["controlEvents"]> = [];
  	const result = await runSync(tempDir, agents, "echo", "Think hard", {
  		runId: "run-inflight",
  		controlConfig: { enabled: true, needsAttentionAfterMs: 200, inFlightSilenceCeilingMs: 100_000, activeNoticeAfterMs: 100_000, notifyOn: ["active_long_running", "needs_attention"] },
  		onControlEvent: (event: NonNullable<RunSyncResult["controlEvents"]>[number]) => controlEvents.push(event),
  	});
  	assert.equal(result.exitCode, 0);
  	assert.ok(!controlEvents.some((e) => e.type === "needs_attention"), "must not flag needs_attention mid-turn");
  });

  it("escalates a silent in-flight turn past the ceiling to needs_attention", async () => {
  	mockPi.onCall({
  		steps: [
  			{ jsonl: [events.messageStart()] },
  			{ delay: 1_300, jsonl: [events.assistantMessage("done")] },
  		],
  	});
  	const agents = makeAgentConfigs(["echo"]);
  	const controlEvents: NonNullable<RunSyncResult["controlEvents"]> = [];
  	const result = await runSync(tempDir, agents, "echo", "Think hard", {
  		runId: "run-ceiling",
  		controlConfig: { enabled: true, needsAttentionAfterMs: 200, inFlightSilenceCeilingMs: 500, activeNoticeAfterMs: 100_000, notifyOn: ["active_long_running", "needs_attention"] },
  		onControlEvent: (event: NonNullable<RunSyncResult["controlEvents"]>[number]) => controlEvents.push(event),
  	});
  	assert.equal(result.exitCode, 0);
  	assert.ok(controlEvents.some((e) => e.type === "needs_attention"), "must escalate once silence exceeds the ceiling");
  });
  ```

  (If `runSync`/`makeAgentConfigs` are local helpers in `single-execution.test.ts` rather than exported, lift the minimal harness into the new file or import from `test/support`; match whatever `single-execution.test.ts` does.)

- [ ] **Step 3: Run, confirm failure**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/integration/foreground-in-flight-control.test.ts 2>&1 | tail -20`
  Expected: FAIL - first case emits `needs_attention` (no in-flight awareness yet).

- [ ] **Step 4: Initialize the lifecycle fields on `progress`**

  In the `const progress: AgentProgress = {...}` literal (~L214), after `lastActivityAt: startTime,`:
  ```typescript
  		turnOpen: false,
  		lastProductiveSignalAt: startTime,
  ```

- [ ] **Step 5: Update lifecycle on every parsed child line**

  In `processLine`, immediately after `progress.lastActivityAt = now;` (before `updateActivityState(now)`), fold the event through the reducer. Compute `hasToolCall` for `message_end` using the same logic already present later in the function (`stopReason`/`toolCall` content check) - extract it to a local so it is computed once:
  ```typescript
  	const lifecycle = applyChildEventToLifecycle(
  		{ turnOpen: progress.turnOpen, lastProductiveSignalAt: progress.lastProductiveSignalAt },
  		{
  			type: evt.type,
  			hasToolCall: evt.type === "message_end" && Array.isArray(evt.message?.content)
  				&& evt.message.content.some((part) => (part as { type?: string }).type === "toolCall"),
  		},
  		now,
  	);
  	progress.turnOpen = lifecycle.turnOpen;
  	progress.lastProductiveSignalAt = lifecycle.lastProductiveSignalAt;
  ```
  Add `applyChildEventToLifecycle` to the existing import from `../shared/subagent-control.ts` (confirmed at `execution.ts:31-35`).

- [ ] **Step 6: Thread the new inputs into `deriveActivityState`**

  In `updateActivityState`, extend the `deriveActivityState({...})` call:
  ```typescript
  			inFlightTurn: progress.turnOpen,
  			lastProductiveSignalAt: progress.lastProductiveSignalAt,
  ```

- [ ] **Step 7: Run, confirm pass**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/integration/foreground-in-flight-control.test.ts 2>&1 | tail -20`
  Expected: PASS (both cases).

- [ ] **Step 8: Run the full foreground suite for regressions**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/integration/single-execution.test.ts 2>&1 | tail -10`
  Expected: PASS.

- [ ] **Step 9: Commit**

  ```bash
  git add src/runs/foreground/execution.ts test/support/helpers.ts test/integration/foreground-in-flight-control.test.ts
  git commit -m "Wire in-flight-turn awareness into foreground control watchdog"
  ```

### Task 6: Background runner wiring

**TDD scenario:** Modifying tested code - run existing integration suites first, keep them green; the in-flight logic itself is covered by the Wave 2 composition unit test.

**Files:**
- Modify: `src/runs/background/subagent-runner.ts`

- [ ] **Step 1: Baseline existing runner tests**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/integration/async-execution.test.ts test/integration/parallel-execution.test.ts 2>&1 | tail -10`
  Expected: PASS (record baseline before editing).

- [ ] **Step 2: Add lifecycle fields to `RunnerStatusStep`**

  At the `RunnerStatusStep` type (~L828), extend the intersection:
  ```typescript
  type RunnerStatusStep = NonNullable<AsyncStatus["steps"]>[number] & {
  	exitCode?: number | null;
  	turnOpen?: boolean;
  	lastProductiveSignalAt?: number;
  };
  ```

- [ ] **Step 3: Reset the fields on step (re)start**

  In `resetStepLiveDetail` (~L174), add:
  ```typescript
  	step.turnOpen = false;
  	step.lastProductiveSignalAt = undefined;
  ```
  This runs on every step start/retry/resume (called at L1576, L1812, L1979), preventing a stale open-turn flag from leaking across attempts. Initial construction (~L974) and dynamic-step construction (~L1496) leave them `undefined`, which `deriveActivityState` treats as "not in flight" / baseline `startedAt` - correct for a not-yet-started step.

- [ ] **Step 4: Update lifecycle in `updateStepFromChildEvent`**

  In `updateStepFromChildEvent`, just before the trailing `step.lastActivityAt = now;` (~L1294), fold the event through the reducer. Reuse the existing assistant `message_end` detection; compute `hasToolCall` from the event message content:
  ```typescript
  	const lifecycle = applyChildEventToLifecycle(
  		{ turnOpen: step.turnOpen, lastProductiveSignalAt: step.lastProductiveSignalAt },
  		{
  			type: event.type,
  			hasToolCall: event.type === "message_end" && Array.isArray(event.message?.content)
  				&& event.message.content.some((part) => (part as { type?: string }).type === "toolCall"),
  		},
  		now,
  	);
  	step.turnOpen = lifecycle.turnOpen;
  	step.lastProductiveSignalAt = lifecycle.lastProductiveSignalAt;
  ```
  Add `applyChildEventToLifecycle` to the existing import from `../shared/subagent-control.ts` (the file already imports `deriveActivityState` and `buildControlEvent` from there - confirmed at `subagent-runner.ts:35`).

- [ ] **Step 5: Thread the new inputs into `deriveActivityState`**

  In `updateRunnerActivityState` (~L1305), extend the `deriveActivityState({...})` call:
  ```typescript
  				inFlightTurn: step.turnOpen,
  				lastProductiveSignalAt: step.lastProductiveSignalAt,
  ```

- [ ] **Step 6: Run runner suites, confirm green**

  Run: `env -u PI_CODING_AGENT_DIR node --experimental-strip-types --test test/integration/async-execution.test.ts test/integration/parallel-execution.test.ts test/integration/async-status.test.ts 2>&1 | tail -10`
  Expected: PASS (no regression).

- [ ] **Step 7: Commit**

  ```bash
  git add src/runs/background/subagent-runner.ts
  git commit -m "Wire in-flight-turn awareness into background runner watchdog"
  ```

---

## Final verification

- [ ] Run the full unit + integration suites:
  ```bash
  env -u PI_CODING_AGENT_DIR npm run test:unit
  npm run test:integration
  ```
  Expected: all green.
