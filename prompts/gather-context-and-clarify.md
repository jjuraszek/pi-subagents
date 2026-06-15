---
description: Use subagents to gather context, then ask clarifying questions
---

Based on our discussion and my intent, launch focused context-gathering subagents before planning or implementing.

Use `scout` to inspect the relevant local files, existing patterns, constraints, tests, and likely integration points. When the request references a URL/issue/PR/doc, use `context-builder` to read it with the `fetch` tool.

Give each subagent a specific meta prompt. Ask them to return concise findings plus the remaining clarification questions that matter for implementation confidence.

After they return, synthesize what we know and use the `interview` tool to ask me the unresolved questions needed to reach a shared understanding.

$@
