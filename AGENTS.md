# pi-subagents (jjuraszek fork)

Pi extension. Lets Pi delegate work to focused child agents: code review, scouting, implementation, parallel audits, saved chains, background/async jobs, intercom-coordinated multi-agent workflows.

This repo is a **fork of [`nicobailon/pi-subagents`](https://github.com/nicobailon/pi-subagents)**, maintained because upstream is slow to merge. It is consumed by Pi via git **tag** pins, not npm. See [Fork & release model](#fork--release-model).

## Communication Style

Same rules as the parent `~/.pi/agent*/AGENTS.md`. Applies to chat, commit messages, PR descriptions, code review, any artifact authored here.

- **Suppress process narration.** No intent classification, phase announcements, tool/subagent preamble, status updates, pleasantries. Start with substance.
- **Output instead:** outcomes, decisions needing input, verification results, blockers.
- **Bullets over prose. Short paragraphs.** No wall-of-text, no tutorial tone unless asked.
- **End on the ask, not a summary.** Diffs/outputs speak for themselves.
- **Match the recipient's register** in human-facing artifacts.

LLM-readable artifacts (`AGENTS.md`, `README.md`, `CHANGELOG.md`, skill bodies, agent personas, spec docs, code comments where the *why* is non-obvious) stay structured: tables, headings, explicit field references, code blocks. Optimize for retrieval over readability.

## Code & Documentation Discipline

- **Code is a liability.** Add only what the task requires. No premature abstractions, no helpers for hypothetical reuse, no fallbacks for branches that can't happen, no commented-out alternatives.
- **No belt-and-suspenders.** Don't validate / null-check / guard the same thing at multiple layers — validate at the boundary once.
- **Delete dead code, don't comment it out.** Branch from the deletion commit if reversibility matters.
- **Comments only when the *why* is non-obvious.** No docstrings on self-evident params/returns. No banner/separator comments. Don't reference the current task or PR — that belongs in the commit message.
- **Markdown tables use compact `|---|` separators.** Never padded columns.
- **Surface, don't auto-fix.** A bug fix doesn't drag in surrounding cleanup; mention adjacent issues separately.

## Fork & release model

This fork is consumed via **git tag pins** in pi `settings.json`, e.g.
`"git:github.com/jjuraszek/pi-subagents@v0.26.0-jj.1"`. There is **no npm
publish** in the loop — do not run `npm publish`.

### Tag scheme

`v<upstream-base>-jj.<n>` where:

| Part | Meaning |
|---|---|
| `<upstream-base>` | the exact upstream `vX.Y.Z` release this fork's `main` is rebased onto |
| `jj` | fork marker (Jacek Juraszek) — distinguishes our tags from upstream's plain `vX.Y.Z` |
| `<n>` | fork patch number on top of that upstream base, starting at `1` |

Examples: `v0.26.0-jj.1`, `v0.26.0-jj.2` (another fork-only change on the same
base), `v0.27.0-jj.1` (rebased onto upstream v0.27.0, fork counter reset).

`package.json` `version` mirrors the tag without the `v` (`0.26.0-jj.1`).

> **Ordering caveat:** semver treats `0.26.0-jj.1` as a *prerelease* of
> `0.26.0` (sorts *before* it), even though our fork is *ahead* of upstream
> v0.26.0. This is harmless: pi git pins resolve the **exact tag string**, not
> a semver range. The base = "upstream release we branched from" is chosen for
> traceability, not range resolution.

### Staying current with upstream

`upstream` remote = `nicobailon/pi-subagents`. `origin` = `jjuraszek/pi-subagents`.

Periodically:

```bash
git fetch upstream --tags
git rebase upstream/main          # replay our fork commits on top
# resolve conflicts (CHANGELOG.md [Unreleased] entries are the usual one)
npm install && env -u PI_CODING_AGENT_DIR npm run test:unit   # see Testing note
bash .agents/skills/release/scripts/release.sh rebase <new-upstream-version>
```

Keep fork commits **linear** on top of upstream — rebase, don't merge — so each
upstream pull stays cheap. Our `main` is force-pushed to `origin` on rebase
(`--force-with-lease`); origin/main is a mirror of local, not an independent line.

### Running a release

Use the `release` skill (`.agents/skills/release/scripts/release.sh`):

```bash
bash .agents/skills/release/scripts/release.sh fork                 # base unchanged, bump -jj.<n>
bash .agents/skills/release/scripts/release.sh rebase 0.27.0        # new upstream base, reset to -jj.1
bash .agents/skills/release/scripts/release.sh --dry-run fork
```

The script bumps `package.json`, commits, creates+pushes the `v…-jj.N` tag,
force-pushes `main`, then rewrites every `~/.pi/agent*/settings.json` pin of
`git:github.com/jjuraszek/pi-subagents@<ref>` to the new tag. See the skill for
flags (`--dry-run`, `--no-update-pins`) and failure handling.

## Fork patches on top of upstream

Track what we carry beyond upstream so rebases are predictable:

| Patch | Commit subject | Upstream status |
|---|---|---|
| agentOverrides for custom agents | "Apply subagents.agentOverrides to user/project custom agents" | [PR #219](https://github.com/nicobailon/pi-subagents/pull/219), unmerged |
| flat discovery + precedence + skip `SKILL.md` | "Discover agents/chains flat with explicit precedence" | fork-only |

The flat-discovery patch is the single source of truth for persona precedence. It lives in `resolveUserAgentDirs()` / `preferredUserAgentDir()` (`src/agents/agents.ts`) plus the `listFilesFlat` / `isAgentFileName` / `isChainFileName` helpers. Precedence (lowest→highest): `builtin < ~/.agents < <PI_CODING_AGENT_DIR>/agents < <repo>/.agents < <repo>/.pi/agents`. Reads are flat (top-level only); `SKILL.md` and `*.chain.md` are never agents. `PI_CODING_AGENT_DIR` relocates the pi profile root but is **not** a discovery sandbox.

When a patch lands upstream, drop it from this table and from the rebase.

## Testing

- `npm run test:unit` (node `--test` with type-stripping), `npm run test:integration`, `npm run test:all`.
- **Unit tests that exercise user-scope discovery set `HOME`/`USERPROFILE` to a temp dir.** A configured `PI_CODING_AGENT_DIR` (present in any real pi harness shell) overrides `HOME` and makes ~17 user-scope tests fail spuriously. Run with it cleared:

  ```bash
  env -u PI_CODING_AGENT_DIR npm run test:unit
  ```

- No `tsc` ships in this repo; type-stripping at test time is the typecheck.

## Routing

| Want to … | Read |
|---|---|
| Install, configure, slash commands, agent/chain authoring | [`README.md`](README.md) |
| What changed across versions | [`CHANGELOG.md`](CHANGELOG.md) |
| Agent/chain discovery, overrides, scopes | `src/agents/agents.ts` |
| Run a release / sync upstream | `.agents/skills/release/SKILL.md` |
| Implementation of a runtime behavior | the matching `src/**/*.ts` directly |
