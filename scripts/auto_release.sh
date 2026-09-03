#!/usr/bin/env bash
# Auto-release: bump the patch version, update CHANGELOG.md, commit, tag, push.
#
# Runs in CI on pushes to main and the 2h schedule (the `release` job in
# .github/workflows/ci.yml). The publish job runs only from tag refs (pub.dev's
# OIDC check rejects branch refs); this script dispatches CI on the fresh tag
# because GITHUB_TOKEN pushes do not trigger workflows (workflow_dispatch is
# exempt) — the default GITHUB_TOKEN is enough, no PAT secret required.
#
# Changelog rules:
# - a curated `## Unreleased` section becomes the new version's notes;
# - otherwise notes are generated from commit subjects since the last tag;
# - a fresh empty `## Unreleased` is appended at the end.
#
# Retries the whole bump from origin/main when another push races it.
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Emit a job output line when running under Actions (no-op locally).
out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$1" >>"$GITHUB_OUTPUT"; fi; }

# Coalescing guards: pub.dev rate-limits publishes (~12/day), so releases are
# capped at one per 2h; runs with nothing new since the last tag are skipped.
git fetch origin main --tags --quiet
last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [ -n "$last_tag" ]; then
  pending=$(git rev-list --count "$last_tag..origin/main")
  if [ "$pending" -eq 0 ]; then
    out "released=false"
    echo "Auto-release: nothing new since $last_tag, skipping."
    exit 0
  fi
  tag_age=$(( $(date +%s) - $(git log -1 --format=%ct "$last_tag") ))
  if [ "$tag_age" -lt 7200 ]; then
    out "released=false"
    echo "Auto-release: coalesced — $last_tag is ${tag_age}s old (<2h); $pending commit(s) pending. Next eligible push or the 2h cron will release them."
    exit 0
  fi
fi

for attempt in 1 2 3; do
  git fetch origin main
  git reset --hard origin/main

  current=$(grep '^version:' pubspec.yaml | awk '{print $2}')
  # Other workflows may tag releases without bumping pubspec — when tags
  # raced ahead, bump from the latest tag instead, or every run dies on
  # "tag already exists".
  latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [ -n "$latest_tag" ]; then
    tag_version="${latest_tag#v}"
    if [ "$(printf '%s\n%s\n' "$current" "$tag_version" | sort -V | tail -1)" = "$tag_version" ]; then
      current="$tag_version"
    fi
  fi
  IFS='.' read -r major minor patch <<< "$current"
  next="$major.$minor.$((patch + 1))"
  echo "Auto-release: v$current -> v$next (attempt $attempt)"

  last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [ -n "$last_tag" ]; then range="$last_tag..HEAD"; else range="HEAD"; fi
  bullets=$(git log "$range" --pretty='- %s' --no-merges | grep -v '^- chore(release):' || true)
  [ -z "$bullets" ] && bullets="- Maintenance release."

  NEXT="$next" BULLETS="$bullets" python3 - <<'PY'
import os
import re

nxt = os.environ["NEXT"]
bullets = os.environ["BULLETS"].strip()
path = "CHANGELOG.md"
text = open(path, encoding="utf-8").read() if os.path.exists(path) else "# Changelog\n\n"
section = f"## {nxt}\n\n{bullets}\n"

m = re.search(r"^## Unreleased[ \t]*$", text, re.M)
if m:
    rest = text[m.end():]
    head = re.search(r"^## ", rest, re.M)
    body = rest[: head.start()] if head else rest
    tail = rest[head.start():] if head else ""
    if body.strip():
        # Curated Unreleased content becomes this release's notes.
        new_section = f"## {nxt}\n" + body.rstrip() + "\n"
    else:
        new_section = section
    text = text[: m.start()] + new_section + ("\n" + tail if tail else "")
else:
    text = text.rstrip() + "\n\n" + section

text = text.rstrip() + "\n\n## Unreleased\n"
open(path, "w", encoding="utf-8").write(text)
PY

  sed -i "s/^version: .*/version: $next/" pubspec.yaml

  git add pubspec.yaml CHANGELOG.md
  git commit -m "chore(release): v$next"
  # Annotated tag: --follow-tags only pushes annotated tags, lightweight
  # ones stay local. --atomic makes main+tag land together or not at all.
  git tag -a "v$next" -m "Release v$next"
  if git push --atomic origin main --follow-tags; then
    out "released=true"
    out "tag=v$next"
    # GitHub Release page for the tag (GITHUB_TOKEN suffices — creating a
    # release is not a push event and triggers no recursion). Notes are
    # commit-derived; CHANGELOG.md stays the curated source.
    if command -v gh >/dev/null 2>&1; then
      gh release create "v$next" --title "v$next" --generate-notes || \
        echo "WARN: gh release create failed (tag exists; release page skipped)"
    fi
    # The tag push above triggers no workflow run (GITHUB_TOKEN pushes do not
    # start workflows), so dispatch CI on the new tag ourselves: workflow_dispatch
    # events are exempt, and the dispatched run carries refs/tags/v$next
    # (refType=tag), which is what pub.dev's OIDC check requires. Dispatch
    # propagation can lag — retry briefly. Failure here is fatal: a silently
    # skipped dispatch strands the publish (exactly how v0.2.6 never reached pub.dev).
    dispatched=false
    for d in 1 2 3; do
      if gh workflow run CI --ref "v$next"; then dispatched=true; break; fi
      echo "CI dispatch attempt $d failed (propagation can lag); retrying..."
      sleep 5
    done
    if [ "$dispatched" != true ]; then
      echo "ERROR: could not dispatch CI on v$next — publish would be stranded, failing the release job"
      exit 1
    fi
    echo "Released v$next"
    exit 0
  fi
  echo "Push raced with another commit, rebasing and retrying..."
  git tag -d "v$next" >/dev/null 2>&1 || true
done

echo "Auto-release failed after 3 attempts"
exit 1
