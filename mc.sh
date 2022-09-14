#!/bin/env bash
set -e

if [ -z "${1}" ]
then
  clusters=(east west)
else
  clusters=("${@:1}")
fi


for c in "${clusters[@]}"
{
  # Load config
  civo k8s config "${c}" > ~/.kube/configs/"${c}"
  chmod 600 ~/.kube/configs/"${c}"
  # export KUBECONFIG=~/.kube/configs/"${c}"
  civo k8s config "${c}" > ~/.kube/config

  ## Install Viz
  helm install grafana -n grafana --create-namespace grafana/grafana -f https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml --wait || true
  linkerd viz install --set grafana.url=grafana.grafana:3000 | kubectl apply -f - || true
  # linkerd check

  ## Install mc
  linkerd multicluster install | kubectl apply -f - || true
  # linkerd check

  ## Failover
  helm install linkerd-failover -n linkerd-failover --create-namespace linkerd/linkerd-failover || true

  ## Allow BCloud

  kubectl apply -f manifests/finalizers/allow-bcloud.yaml

  linkerd check
  # unset KUBECONFIG
}
linkerd multicluster link  --kubeconfig ~/.kube/configs/west --cluster-name west | kubectl apply --kubeconfig ~/.kube/configs/east -f -
linkerd multicluster link  --kubeconfig ~/.kube/configs/east --cluster-name east | kubectl apply --kubeconfig ~/.kube/configs/west -f -


