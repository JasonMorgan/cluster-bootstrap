#!/bin/env bash
set -e

if [[ -z "${2}" ]]
then
  domain="civo.59s.io"
else
  domain="${2}"
fi

if [[ -z "${1}" ]]
then
  echo "./update-wildcard.sh ipAddress [domain]"
  exit 1
else
  ipAddress="${1}"
fi

#civo domain record remove civo.59s.io 914123f2-0981-47d1-97c4-546b56c610ea
civo domain record ls civo.59s.io
read -r -p "enter old wildcard record id: " id
civo domain record delete civo.59s.io "${id}" -y
civo domain record add "${domain}" -n '*' -e A -v "${ipAddress}"

## Add finalizers to east

kubectl apply --kubeconfig ~/.kube/configs/east -f manifests/finalizers/
