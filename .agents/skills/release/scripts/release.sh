#!/usr/bin/env bash
set -euo pipefail

# Fork release helper for jjuraszek/pi-subagents.
#
# Tag scheme: v<upstream-base>-jj.<n>  (see AGENTS.md "Fork & release model").
#   <upstream-base>  upstream vX.Y.Z this fork's main is rebased onto
#   jj               fork marker (Jacek Juraszek)
#   <n>              fork patch counter on that base, starting at 1
#
# package.json version mirrors the tag without the leading "v".
#
# This fork is consumed via git tag pins in pi settings.json. There is NO npm
# publish step. Do not run `npm publish`.

usage() {
  cat <<'EOF'
Usage:
  release.sh [--dry-run] [--no-update-pins] <mode>

Modes:
  current              Tag the version already in package.json (no bump).
                       Use for the first fork release or when the version was
                       set by hand as part of a feature commit.
  fork                 Bump -jj.<n> (same upstream base), commit, tag, release.
  rebase <X.Y.Z>       Set a new upstream base, reset to -jj.1, commit, tag,
                       release. Run AFTER `git rebase upstream/main`.

Examples:
  release.sh current
  release.sh fork
  release.sh rebase 0.27.0
  release.sh --dry-run fork
  release.sh --no-update-pins current   # skip ~/.pi/agent*/settings.json pin bump

Default behavior: after pushing the new tag, every ~/.pi/agent*/settings.json
that pins this repo (git:github.com/jjuraszek/pi-subagents@<ref>) is rewritten
in-place to @v<version> so subsequent pi launches pick up the release.
EOF
}

DRY_RUN=0
UPDATE_PINS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --no-update-pins) UPDATE_PINS=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                break ;;
  esac
done

MODE="${1:-}"
case "$MODE" in
  current|fork) ;;
  rebase)
    REBASE_BASE="${2:-}"
    if [[ ! "$REBASE_BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: rebase mode requires an upstream base version like 0.27.0" >&2
      exit 1
    fi
    ;;
  "")
    usage; exit 1 ;;
  *)
    echo "error: unknown mode '$MODE'" >&2
    usage >&2
    exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
cd "$REPO_ROOT"

PIN_REPO="github.com/jjuraszek/pi-subagents"
PIN_PREFIX="git:${PIN_REPO}@"

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean; commit or stash changes before releasing" >&2
    git status --short >&2 || true
    exit 1
  fi
}

# echoes the next package.json version string for the chosen mode
compute_next_version() {
  local cur="$1"
  node -e '
    const cur = process.argv[1];
    const mode = process.argv[2];
    const rebaseBase = process.argv[3] || "";
    const m = cur.match(/^(\d+\.\d+\.\d+)-jj\.(\d+)$/);
    if (mode === "current") { process.stdout.write(cur); process.exit(0); }
    if (mode === "rebase") { process.stdout.write(`${rebaseBase}-jj.1`); process.exit(0); }
    // fork
    if (!m) { console.error(`current version ${cur} is not <base>-jj.<n>; use rebase mode`); process.exit(1); }
    process.stdout.write(`${m[1]}-jj.${Number(m[2]) + 1}`);
  ' "$cur" "$MODE" "${REBASE_BASE:-}"
}

update_settings_pins() {
  local new_tag="$1"
  local mode="$2"   # "apply" or "dry"
  local found_any=0
  shopt -s nullglob
  for settings in "$HOME"/.pi/agent*/settings.json; do
    if ! grep -q "${PIN_PREFIX}" "$settings"; then
      continue
    fi
    found_any=1
    if [[ "$mode" == "dry" ]]; then
      echo "would update pin in: $settings"
      grep -nH "${PIN_PREFIX}" "$settings" | sed "s|@[^\"]*|@${new_tag}|" || true
      continue
    fi
    python3 - "$settings" "$PIN_PREFIX" "$new_tag" <<'PY'
import json, sys, pathlib
path, pin_prefix, new_tag = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
data = json.loads(path.read_text())
pkgs = data.get("packages")
if not isinstance(pkgs, list):
    print(f"  skipped (no packages array): {path}")
    sys.exit(0)
changed = []
for i, entry in enumerate(pkgs):
    if isinstance(entry, str) and entry.startswith(pin_prefix):
        old_ref = entry[len(pin_prefix):]
        if old_ref == new_tag:
            continue
        pkgs[i] = pin_prefix + new_tag
        changed.append((old_ref, new_tag))
if not changed:
    print(f"  no-op (already at {new_tag}): {path}")
    sys.exit(0)
path.write_text(json.dumps(data, indent=2) + "\n")
for old, new in changed:
    print(f"  bumped {path}: @{old} -> @{new}")
PY
  done
  shopt -u nullglob
  if [[ "$found_any" -eq 0 ]]; then
    echo "  no ~/.pi/agent*/settings.json files pin ${PIN_REPO}; nothing to bump"
  fi
}

if [[ ! -f package.json ]]; then
  echo "error: package.json not found at repo root: $REPO_ROOT" >&2
  exit 1
fi

OLD_VERSION="$(node -p "require('./package.json').version")"
CURRENT_BRANCH="$(git branch --show-current)"
NEW_VERSION="$(compute_next_version "$OLD_VERSION")"
NEW_TAG="v${NEW_VERSION}"

if git rev-parse -q --verify "refs/tags/${NEW_TAG}" >/dev/null; then
  echo "error: tag ${NEW_TAG} already exists" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run summary:"
  echo "  mode:            $MODE"
  echo "  current version: $OLD_VERSION"
  echo "  new version:     $NEW_VERSION"
  echo "  new tag:         $NEW_TAG"
  echo "  branch:          $CURRENT_BRANCH"
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "  note: working tree is not clean; a real release stops until clean (current mode)."
  fi
  if [[ "$MODE" != "current" ]]; then
    echo "  would set package.json version to $NEW_VERSION and commit"
  fi
  echo "  would run: npm run build --if-present; npm run check --if-present"
  echo "  would create annotated tag $NEW_TAG and push main + tag to origin"
  if [[ "$UPDATE_PINS" -eq 1 ]]; then
    echo "  would bump pi settings.json pins to ${NEW_TAG}:"
    update_settings_pins "$NEW_TAG" dry
  else
    echo "  --no-update-pins given; would skip pin bump"
  fi
  exit 0
fi

if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "error: releases run from main (on '$CURRENT_BRANCH')" >&2
  exit 1
fi

if [[ "$MODE" != "current" ]]; then
  require_clean_tree
  node -e '
    const fs = require("fs");
    const p = require("./package.json");
    p.version = process.argv[1];
    fs.writeFileSync("package.json", JSON.stringify(p, null, 2) + "\n");
  ' "$NEW_VERSION"
  run git add package.json
  run git commit -m "Release ${NEW_VERSION}"
else
  require_clean_tree
fi

run npm run build --if-present
run npm run check --if-present

run git tag -a "$NEW_TAG" -m "Release ${NEW_VERSION}"
run git push origin main
run git push origin "$NEW_TAG"

NEW_SHA="$(git rev-parse HEAD)"

if [[ "$UPDATE_PINS" -eq 1 ]]; then
  echo "Updating pi settings.json pins to ${NEW_TAG}:"
  update_settings_pins "$NEW_TAG" apply
else
  echo "Skipping pin update (--no-update-pins). Bump manually if needed:"
  echo "  grep -nrH '${PIN_PREFIX}' \$HOME/.pi/agent*/settings.json"
fi

cat <<EOF
Release complete.
Old version: $OLD_VERSION
New version: $NEW_VERSION
Tag: $NEW_TAG
Commit: $NEW_SHA
Pushed: origin/main and $NEW_TAG
EOF
