/**
 * Integration tests: in-flight turn awareness in the foreground control watchdog.
 *
 * Verifies that a silent gap INSIDE an open turn (after message_start, before
 * message_end) is capped by inFlightSilenceCeilingMs rather than by
 * needsAttentionAfterMs.
 */

import { describe, it, before, after, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import type { MockPi } from "../support/helpers.ts";
import {
	createMockPi,
	createTempDir,
	removeTempDir,
	makeAgentConfigs,
	events,
	tryImport,
} from "../support/helpers.ts";

interface RunSyncResult {
	exitCode: number;
	controlEvents?: Array<{ type?: string; message: string; reason?: string }>;
	progress: { activityState?: string; status: string };
}

interface ExecutionModule {
	runSync(
		runtimeCwd: string,
		agents: ReturnType<typeof makeAgentConfigs>,
		agentName: string,
		task: string,
		options: Record<string, unknown>,
	): Promise<RunSyncResult>;
}

const execution = await tryImport<ExecutionModule>("./src/runs/foreground/execution.ts");
const available = !!execution;
const runSync = execution?.runSync;

describe("foreground in-flight turn control", { skip: !available ? "pi packages not available" : undefined }, () => {
	let tempDir: string;
	let mockPi: MockPi;

	before(() => {
		mockPi = createMockPi();
		mockPi.install();
	});

	after(() => {
		mockPi.uninstall();
	});

	beforeEach(() => {
		tempDir = createTempDir();
		mockPi.reset();
	});

	afterEach(() => {
		removeTempDir(tempDir);
	});

	it("treats a silent in-flight turn under the ceiling as active_long_running, not needs_attention", async () => {
		mockPi.onCall({
			steps: [
				{ jsonl: [events.messageStart()] },
				{ delay: 1_300, jsonl: [events.assistantMessage("done")] },
			],
		});
		const agents = makeAgentConfigs(["echo"]);
		const controlEvents: NonNullable<RunSyncResult["controlEvents"]> = [];
		const result = await runSync!(tempDir, agents, "echo", "Think hard", {
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
		const result = await runSync!(tempDir, agents, "echo", "Think hard", {
			runId: "run-ceiling",
			controlConfig: { enabled: true, needsAttentionAfterMs: 200, inFlightSilenceCeilingMs: 500, activeNoticeAfterMs: 100_000, notifyOn: ["active_long_running", "needs_attention"] },
			onControlEvent: (event: NonNullable<RunSyncResult["controlEvents"]>[number]) => controlEvents.push(event),
		});
		assert.equal(result.exitCode, 0);
		assert.ok(controlEvents.some((e) => e.type === "needs_attention"), "must escalate once silence exceeds the ceiling");
	});
});
