---
name: release
description: Creates a fork release for jjuraszek/pi-subagents and syncs upstream. Use when asked to release, bump the fork version, cut a tag, or rebase onto a new upstream version. This fork is consumed via git tag pins (git:github.com/jjuraszek/pi-subagents@vX.Y.Z-jj.N); there is no npm publish step.
---

# Release

Use this skill when asked to release this package or to sync it with upstream.

## Repository-specific release model

This fork is consumed via **git tag pins** in pi `settings.json` (e.g.
`"git:github.com/jjuraszek/pi-subagents@v0.26.0-jj.1"`), not via npm. A release here means:

1. set the fork version in `package.json`
2. create the release commit (non-`current` modes) and the matching `v<version>` git tag
3. push `main` and the tag to `origin`
4. rewrite every `~/.pi/agent*/settings.json` that pins this repo so its `@<old-ref>` becomes `@v<version>` (done by the helper script)

There is no CI publish workflow. **Do not run `npm publish`** — nothing consumes the npm package.

## Tag scheme

`v<upstream-base>-jj.<n>` — see [AGENTS.md](../../../AGENTS.md) "Fork & release model".

| Part | Meaning |
|---|---|
| `<upstream-base>` | upstream `vX.Y.Z` this fork's `main` is rebased onto |
| `jj` | fork marker (Jacek Juraszek) |
| `<n>` | fork patch counter on that base, from `1` |

`package.json` `version` mirrors the tag without the `v`.

## Modes

| Mode | When | Effect |
|---|---|---|
| `current` | first fork release, or version already hand-set in a feature commit | tags the version in `package.json` as-is, no bump, no extra commit |
| `fork` | another fork-only change on the same upstream base | bumps `-jj.<n>`, commits `Release <version>`, tags |
| `rebase <X.Y.Z>` | after `git rebase upstream/main` onto a new upstream release | sets base to `X.Y.Z`, resets to `-jj.1`, commits, tags |

## Safety checks before releasing

- working tree is clean (for `current`, commit your feature work first — `current` tags HEAD as-is)
- releasing from `main`
- local `main` can fast-forward from `origin/main`
- the target `v<version>` tag does not already exist (script enforces this)

If any check fails, stop and explain why.

## Preferred execution path

```bash
bash .agents/skills/release/scripts/release.sh current
bash .agents/skills/release/scripts/release.sh fork
bash .agents/skills/release/scripts/release.sh rebase 0.27.0
```

Validation run (no side effects):

```bash
bash .agents/skills/release/scripts/release.sh --dry-run fork
```

Release without touching settings.json pins (rare):

```bash
bash .agents/skills/release/scripts/release.sh --no-update-pins current
```

## Syncing upstream

`upstream` = `nicobailon/pi-subagents`, `origin` = `jjuraszek/pi-subagents`.

```bash
git fetch upstream --tags
git rebase upstream/main          # replay fork commits; resolve CHANGELOG conflicts
npm install
env -u PI_CODING_AGENT_DIR npm run test:unit   # PI_CODING_AGENT_DIR breaks user-scope tests
git push --force-with-lease origin main
bash .agents/skills/release/scripts/release.sh rebase <new-upstream-version>
```

Keep fork commits linear (rebase, never merge). When a fork patch lands upstream, drop it during the rebase and update the fork-patch table in AGENTS.md.

## What the helper script does

1. resolves repo root from the script path; reads `package.json` version
2. computes the next version per mode
3. fails if the target tag already exists
4. `--dry-run`: prints the plan (incl. which settings.json pins would change) and exits
5. otherwise: verifies `main`, (non-`current`) bumps + commits, runs `npm run build/check --if-present`, creates annotated tag, pushes `main` + tag
6. rewrites `~/.pi/agent*/settings.json` pins of `git:github.com/jjuraszek/pi-subagents@<ref>` to the new tag (unless `--no-update-pins`)
