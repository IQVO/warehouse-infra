#!/usr/bin/env bash
# Pin the images a publish-images run pushed (ADR 0011).
#
#     scripts/k3s-pin-images.sh <run-id>            # merge into terraform/targets/k3s.images.yaml
#     scripts/k3s-pin-images.sh --latest            # the newest successful run on develop
#
# terraform/20-apps (image_source = registry) reads that file for the tag of
# every application's image and frontend image; it builds nothing. A run that
# built only some applications (`apps:` input) updates only those entries.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="${repo}/terraform/targets/k3s.images.yaml"
slug="IQVO/warehouse-infra"

run="${1:-}"
[[ -n "${run}" ]] || { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
if [[ "${run}" == --latest ]]; then
  run="$(gh run list -R "${slug}" --workflow publish-images.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')"
  [[ -n "${run}" ]] || { echo "error: no successful publish-images run" >&2; exit 1; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
echo "==> downloading the results of run ${run}" >&2
gh run download "${run}" -R "${slug}" -p 'result-*' -D "${tmp}"

python3 - "${lock}" "${tmp}" "${run}" <<'PY'
import json, pathlib, sys
import yaml

lock, tmp, run = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
doc = yaml.safe_load(lock.read_text()) if lock.exists() else {}
doc = doc or {}
images = doc.get("images") or {}
n = 0
for f in sorted(tmp.glob("*/*.json")):
    r = json.loads(f.read_text())
    entry = images.setdefault(r["app"], {})
    entry["image" if r["kind"] == "service" else "frontend"] = r["tag"]
    n += 1
doc = {"run": int(run), "images": dict(sorted(images.items()))}
header = (
    "# Written by scripts/k3s-pin-images.sh from a publish-images run (ADR 0011).\n"
    "# image: tag of ghcr.io/iqvo/warehouse-infra/<app>; frontend: tag of <app>-frontend.\n"
)
lock.write_text(header + yaml.safe_dump(doc, sort_keys=False))
print(f"pinned {n} image(s) from run {run} -> {lock}", file=sys.stderr)
PY
