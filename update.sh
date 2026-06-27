#!/usr/bin/env bash
# Updates the odysseus source pin and regenerates venv package lockfiles.
# Run this whenever you want to pull in a new upstream commit or bump deps.
# Commit npins/sources.json, requirements.lock, requirements-whisper.lock.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Updating odysseus source pin..."
npins update odysseus

echo "==> Regenerating requirements.lock..."
uv pip compile requirements.in \
  --python-version 3.12 \
  --generate-hashes \
  --no-header \
  --output-file requirements.lock

echo "==> Regenerating requirements-whisper.lock..."
uv pip compile requirements-whisper.in \
  --python-version 3.12 \
  --generate-hashes \
  --no-header \
  --output-file requirements-whisper.lock

echo ""
echo "Done — review and commit:"
echo "  npins/sources.json"
echo "  requirements.lock"
echo "  requirements-whisper.lock"
