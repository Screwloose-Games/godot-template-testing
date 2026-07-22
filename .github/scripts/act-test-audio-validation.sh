#!/usr/bin/env bash
#
# Exercise the "Validate Audio Files" workflow end-to-end with `act`, running the
# REAL tj-actions/changed-files action in Docker -- the piece that can't be
# simulated (its output escaping is why this check broke twice).
#
# Usage:
#   .github/scripts/act-test-audio-validation.sh bad    # PR adds badly-named files -> job should FAIL
#   .github/scripts/act-test-audio-validation.sh good   # PR adds well-named files  -> Validate step should PASS
#
# Requires: act + a running Docker daemon, and the catthehacker/ubuntu:act-latest
# image (act pulls it on first run).
#
# It builds a throwaway git repo in a temp dir (your real working tree is never
# touched), copies in the actual workflow + scripts, creates a base commit and a
# PR branch, crafts a pull_request event, and runs act against it.
#
# Note: the "Comment PR" step will fail under act because it can't reach GitHub's
# API to post a comment -- that's an act limitation, not a workflow bug. The
# meaningful signal is the "Validate audio files" step's result.
set -euo pipefail

MODE="${1:-bad}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Repo:      $REPO_ROOT"
echo "Scratch:   $WORK"
echo "Scenario:  $MODE"
echo

cd "$WORK"
mkdir -p .github/workflows .github/scripts common/audio/music
cp "$REPO_ROOT/.github/workflows/validate-audio-files.yml" .github/workflows/
cp -r "$REPO_ROOT/.github/scripts/." .github/scripts/
rm -rf .github/scripts/__pycache__

git init -q -b main
git config user.email test@example.com
git config user.name  act-test
git config commit.gpgsign false

# Base: repo already contains one compliant track.
printf 'OggS base' > "common/audio/music/existing_track.ogg"
git add -A && git commit -q -m "base"
BASE_SHA="$(git rev-parse HEAD)"

# PR branch adds new audio files (bad or good names depending on scenario).
git checkout -q -b pr-branch
if [ "$MODE" = "good" ]; then
  printf 'OggS a' > "common/audio/music/ive_got_your_back_intro.ogg"
  printf 'OggS b' > "common/audio/music/outside_the_colosseum.ogg"
else
  printf 'OggS a' > "common/audio/music/I've Got Your Back! (Intro).ogg"
  printf 'OggS b' > "common/audio/music/Outside the Colosseum.ogg"
  printf 'OggS c' > "common/audio/music/good_new_track.ogg"
fi
git add -A && git commit -q -m "add music"
HEAD_SHA="$(git rev-parse HEAD)"

cat > event.json <<EOF
{
  "pull_request": {
    "number": 1,
    "base": { "sha": "$BASE_SHA", "ref": "main" },
    "head": { "sha": "$HEAD_SHA", "ref": "pr-branch" }
  },
  "repository": {
    "name": "godot-jam-template",
    "full_name": "Screwloose-Games/godot-jam-template",
    "owner": { "login": "Screwloose-Games" }
  }
}
EOF

echo "Running act..."
echo
act pull_request \
  -W .github/workflows/validate-audio-files.yml \
  --eventpath event.json \
  --bind --pull=false
