# Helpers sourced by the generated chNN/try-it-now.sh scripts.
# Block functions hold the book's commands as printed; traps echo each one and
# count failures so a script keeps going and prints a summary at the end.
set -uo pipefail
set -ET  # ERR and DEBUG traps also fire inside the block functions

commands=0 failures=0 expected_failures=0 skipped=0 nonzero=0
failed_cmds=() nonzero_cmds=() _last_line= _last_cmd=
# Steps that show the process works: deploys, waits, and reaching the app. Only these count as failures.
CHECKS='^(kubectl (apply|create|wait|rollout)|helm (install|upgrade)|browse|hosts_add|pf_start)[[:space:]]' 
pf_pid=
resolve=()   # curl --resolve args standing in for the book's /etc/hosts edits
HELPERS=" settle expected manual pf_stop "

_on_debug() {
  # top-level book commands only, not helpers or $(...) substitutions; stderr so
  # the echo can't end up inside a substitution's output
  ((BASH_SUBSHELL == 0)) && [[ ${FUNCNAME[1]:-} == block_* && $HELPERS != *" ${BASH_COMMAND%% *} "* ]] || return 0
  # DEBUG fires again on the same line before the ERR handler; log each line once
  [[ ${BASH_LINENO[0]} == "$_last_line" ]] && return 0
  _last_line=${BASH_LINENO[0]} _last_cmd=$BASH_COMMAND
  commands=$((commands + 1))
  printf '\033[36m$ %s\033[0m\n' "$BASH_COMMAND" >&2
}
_on_err() {
  ((BASH_SUBSHELL == 0)) && [[ ${FUNCNAME[1]:-} == block_* ]] || return 0
  local where="block ${FUNCNAME[1]#block_}: $_last_cmd"
  if [[ $_last_cmd =~ $CHECKS ]]; then
    failures=$((failures + 1)); failed_cmds+=("$where")
    printf '\033[31mFAILED (exit %s)\033[0m\n' "$1" >&2
  else
    # the book often shows commands that exit non-zero (printenv of an unset var,
    # logs of a crashing app, deleting what another file already deleted)
    nonzero=$((nonzero + 1)); nonzero_cmds+=("$where")
    printf '\033[33mnon-zero exit %s (informational)\033[0m\n' "$1" >&2
  fi
}
trap '_on_debug' DEBUG
trap '_on_err $?' ERR

# `cmd || expected`: the book says cmd fails (policy denial, missing permission, ...).
expected() { expected_failures=$((expected_failures + 1)); echo "(failed, as the book expects)"; }

# Host setup a script can't do (VMs, sudo, other clusters, Docker Desktop internals).
manual() { skipped=$((skipped + 1)); printf '\033[33m- skipped (manual): %s\033[0m\n' "$*"; }

# Commands that never exit on their own (--watch, logs -f): run for a while, then stop.
bounded() {
  local secs=$1; shift
  "$@" & local p=$!
  sleep "$secs"; kill $p 2>/dev/null; wait $p 2>/dev/null
  return 0
}

pf_start() {
  pf_stop
  kubectl port-forward "$@" >/dev/null 2>&1 & pf_pid=$!
  local port=${*: -1}; port=${port%%:*}
  browse "http://localhost:$port"
}
pf_stop() { [[ -n $pf_pid ]] && kill $pf_pid 2>/dev/null && wait $pf_pid 2>/dev/null; pf_pid=; return 0; }

# Stands in for "browse to <url>": fetch it, retrying while the app or an ingress
# route comes up. A 4xx is accepted once retries run out, since some exercises
# show an error page on purpose; -k because the book has you accept cert warnings.
browse() {
  local url=$1 code=000
  for _ in $(seq 15); do
    code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "$url")
    ((10#$code > 0 && 10#$code < 400)) && break
    sleep 3
  done
  echo "browse $url -> HTTP $code"
  ((10#$code > 0 && 10#$code < 500))
}

# Stands in for add-to-hosts.sh: resolve the host to the ingress controller's LB address.
hosts_add() {
  local ip port
  ip=$(kubectl get svc "$2-controller" -n "kiamol-$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
  [[ $ip == localhost ]] && ip=127.0.0.1
  [[ -n $ip ]] || return 1
  for port in 80 443 8015 9443; do resolve+=(--resolve "$1:$port:$ip"); done
  echo "$1 -> $ip"
}
curl() { command curl ${resolve[@]+"${resolve[@]}"} "$@"; }

# After deploy commands: wait for Deployments and LoadBalancer addresses, as the
# book's reader would. Not fatal: some exercises deploy things meant to stay broken.
settle() {
  kubectl wait --for=condition=Available deploy --all -A --timeout=45s >/dev/null 2>&1
  for _ in $(seq 30); do
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}[{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}]{end}' 2>/dev/null |
      grep -q '\[\]' || break
    sleep 3
  done
  return 0
}

# Run the given blocks (default: all), print a summary, exit 1 on unexpected failures.
main() {
  local sel=("$@") b
  if ((${#sel[@]} == 0)); then
    for b in $(declare -F | awk '{print $3}' | grep -E '^block_[0-9]+$' | sort -t_ -k2 -n); do sel+=("${b#block_}"); done
  fi
  for b in "${sel[@]}"; do
    printf '\n\033[1m== %s block %s\033[0m\n' "$chapter" "$b"
    "block_$b"; pf_stop; settle
  done
  echo
  echo "$chapter: $commands commands, $failures failed, $expected_failures failed as the book expects, $nonzero other non-zero, $skipped skipped (manual)"
  for b in ${failed_cmds[@]+"${failed_cmds[@]}"}; do echo "  failed: $b"; done
  for b in ${nonzero_cmds[@]+"${nonzero_cmds[@]}"}; do echo "  non-zero: $b"; done
  ((failures == 0))
}
