#!/usr/bin/env bash
# Build every service image on Cloud Build (linux/amd64) and push to Artifact
# Registry. Builds from the repo root, so run it with a clean working tree.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
REPO_ROOT="$(cd ../.. && pwd)"

# Tag by commit, but a dirty tree gets a timestamp so two builds of different
# working trees never collide on one tag.
if [ -z "${TAG:-}" ]; then
  sha="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$sha" ] && [ -z "$(cd "$REPO_ROOT" && git status --porcelain)" ]; then
    TAG="$sha"
  else
    TAG="${sha:-src}-$(date +%Y%m%d-%H%M%S)"
  fi
fi
echo "Building ${IMAGE_BASE}/*:${TAG}"

# Cloud Build's default SA needs to push to Artifact Registry.
PROJECT_NUMBER="$(gc projects describe "$PROJECT_ID" --format='value(projectNumber)')"
for sa in "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
          "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"; do
  gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa}" --role=roles/artifactregistry.writer \
    --condition=None >/dev/null 2>&1 || true
done

cd "$REPO_ROOT"

# Build only what changed: `./04-build.sh backend tracking`. The Rust tracking
# image alone takes 10-13 minutes, so rebuilding all seven for a one-service fix
# is the difference between a 2-minute and a 13-minute loop.
CONFIG=deploy/gcp/cloudbuild.yaml
if [ "$#" -gt 0 ]; then
  CONFIG="$(mktemp -t cloudbuild.XXXXXX.yaml)"
  trap 'rm -f "$CONFIG"' EXIT
  SERVICES="$*" python3 - "$CONFIG" <<'PY'
import os, re, sys
want = set(os.environ["SERVICES"].split())
src = open("deploy/gcp/cloudbuild.yaml").read()
head, _, rest = src.partition("steps:\n")
steps_txt, _, images_txt = rest.partition("images:\n")
steps = [s for s in re.split(r"\n(?=  - id: )", steps_txt.strip("\n")) if s.strip()]
keep = [s for s in steps if re.search(r"  - id: (\S+)", s).group(1) in want]
if not keep:
    sys.exit(f"no such service(s): {' '.join(sorted(want))}")
imgs = [l for l in images_txt.splitlines()
        if any(f"/{n}:" in l for n in want)]
open(sys.argv[1], "w").write(
    head + "steps:\n" + "\n".join(keep) + "\n\nimages:\n" + "\n".join(imgs) + "\n")
PY
  echo "Building only: $*"
fi

gc builds submit \
  --config="$CONFIG" \
  --substitutions="_IMAGE_BASE=${IMAGE_BASE},_TAG=${TAG}" \
  --ignore-file=.gcloudignore \
  .

echo "$TAG" > deploy/gcp/.last-tag
echo "Pushed tag ${TAG}"
