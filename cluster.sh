#!/usr/bin/env bash
# Local kind cluster for the kiamol exercises.
#   ./cluster.sh up    create cluster "kiamol" and start cloud-provider-kind (LoadBalancer IPs)
#   ./cluster.sh down  stop cloud-provider-kind and delete the cluster
set -uo pipefail
provider=kiamol-cloud-provider

case "${1:-}" in
up)
  kind get clusters 2>/dev/null | grep -qx kiamol || kind create cluster --name kiamol --wait 2m || exit
  kind export kubeconfig --name kiamol || exit
  # Runs as a container so it needs no sudo on macOS. The chapters bring their own
  # ingress controllers, so the provider's default ingress and Gateway API are off.
  docker inspect $provider >/dev/null 2>&1 ||
    docker run -d --name $provider --network kind -v /var/run/docker.sock:/var/run/docker.sock \
      registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.12.0 \
      --enable-default-ingress=false --gateway-channel disabled >/dev/null
  ;;
down)
  docker rm -f $provider >/dev/null 2>&1
  kind delete cluster --name kiamol
  ;;
*)
  echo "usage: $0 up|down" >&2; exit 2
  ;;
esac
