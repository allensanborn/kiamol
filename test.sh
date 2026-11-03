#!/usr/bin/env bash
# Check the kiamol manifests still work on current Kubernetes.
#   ./test.sh          schema check every manifest (kubeconform, offline after first run)
#   ./test.sh cluster  server-side dry-run each chapter on a kind cluster, plus one real Pod
#   ./test.sh book [chNN ...]  run the chapters' try-it-now.sh scripts (logs in .test-logs/)
set -uo pipefail
cd "$(dirname "$0")"

# Kubernetes manifests only: skips Compose files, Helm templates and other YAML.
manifests() {
  grep -rlE '^kind:' --include='*.yaml' --include='*.yml' --exclude-dir=docker-images "$1" | xargs grep -L '{{' | sort
}

if [[ "${1:-}" == book ]]; then
  shift; ./cluster.sh up || exit
  chapters=("$@"); ((${#chapters[@]})) || chapters=(ch*)
  mkdir -p .test-logs; failed=0
  for ch in "${chapters[@]}"; do
    [[ -x $ch/try-it-now.sh ]] || continue
    "$ch/try-it-now.sh" >".test-logs/$ch.log" 2>&1 || failed=1
    grep -E "^$ch: " ".test-logs/$ch.log" || echo "$ch: no summary, see .test-logs/$ch.log"
  done
  exit $failed
fi

if [[ "${1:-}" != cluster ]]; then
  # Built-in kinds on removed API versions have no schema, so they fail as "could not find schema".
  manifests . | xargs kubeconform -summary -output text -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  exit
fi

./cluster.sh up || exit

failed=0
for ch in ch*/; do
  ch=${ch%/}
  # Dry-run creates nothing, so drop errors about namespaces/service accounts the chapter itself defines.
  # ponytail: CRD kinds from the same chapter still show as "mapping not found"; apply CRDs first if that noise matters
  errors=$(manifests "$ch" | sed 's/^/-f /' | xargs kubectl apply --dry-run=server 2>&1 >/dev/null |
    grep -E 'rror|mapping not found' | grep -vE '(namespaces|serviceaccount) "[^"]+" not found')
  if [[ -n "$errors" ]]; then
    echo "FAIL $ch ($(wc -l <<<"$errors" | tr -d ' ') errors)"; sed 's/^/  /' <<<"$errors"; failed=1
  else
    echo "ok   $ch"
  fi
done

# Real deploy: proves images pull and run on this architecture.
kubectl apply -f ch02/pod.yaml && kubectl wait --for=condition=Ready -f ch02/pod.yaml --timeout=2m || failed=1
kubectl delete -f ch02/pod.yaml --wait=false >/dev/null
exit $failed
