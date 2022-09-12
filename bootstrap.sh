#!/bin/env bash
set -e

if [ -z "${2}" ]
then
  clusters=(test dev prod1)
else
  clusters=("${2}")
fi

case "${1}" in
  start)
    for c in "${clusters[@]}"
    {
      linkerd_install=(helm install linkerd2 --version 2.11.1 --set-file identityTrustAnchorsPEM=/home/jason/tmp/ca/root.crt  --set-file identity.issuer.tls.crtPEM=/home/jason/tmp/ca/issuer.crt   --set-file identity.issuer.tls.keyPEM=/home/jason/tmp/ca/issuer.key linkerd/linkerd2 --wait)
      ## Is it a Prod cluster?
      if [[ "${c}" == "prod"* ]]
      then
        size=g4s.kube.large
        linkerd_install+=(-f manifests/linkerd/values-ha.yaml)
        # linkerd_install+=(-f manifests/linkerd/overrides.yaml)
      else
        size=g4s.kube.small
      fi
      ## Create Cluster
      civo k8s create "${c}" -n 3 -s "${size}" -r Traefik-v2-nodeport -w || true
      civo k8s config "${c}" > ~/tmp/"${c}"
      chmod 600 ~/tmp/"${c}"
      export KUBECONFIG=~/tmp/"${c}"

      ## Install Apps
      "${linkerd_install[@]}"
      /home/jason/.linkerd2/bin/linkerd-stable-2.11.4 check
      helm install --create-namespace --namespace buoyant-cloud  --values manifests/buoyant/values.yaml --set managed=true --set metadata.agentName="${c}" --set controlPlaneOperator.extendedRBAC.enabled=true linkerd-buoyant linkerd-buoyant/linkerd-buoyant
      helm install front-door nginx-stable/nginx-ingress -f manifests/nginx-ingress/values.yaml -n nginx-ingress --create-namespace --wait
      helm install cert-manager jetstack/cert-manager --create-namespace --namespace cert-manager -f manifests/cert-manager/values.yaml --wait
      curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | linkerd inject - | kubectl apply -f -
      kubectl create ns booksapp
      curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/booksapp.yml | linkerd inject - | kubectl apply -n booksapp -f -
      
      ## Create BCloud Config
       if [[ "${c}" == "prod"* ]]
      then
        kubectl apply -f manifests/buoyant/dataplane-prod.yaml
        kubectl apply -f manifests/buoyant/controlplane-prod.yaml
      else
        kubectl apply -f manifests/buoyant/dataplane.yaml
        kubectl apply -f "manifests/buoyant/controlplane-${c}.yaml"
      fi
      unset KUBECONFIG
    }
  ;;
  stop)
    for c in "${clusters[@]}"
    {
      civo k8s delete "${c}" -y
    }
  ;;
  *)
    echo "missing required argument: start|stop"
    echo "./bootstrap start|stop [cluster names]"
    exit 1
  ;;
esac

