#!/bin/env bash
set -e

if [ -z "${2}" ]
then
  clusters=(test dev prod1)
else
  clusters=("${@:2}")
fi

case "${1}" in
  start)
    for c in "${clusters[@]}"
    {
      helm repo update > /dev/null

      linkerd_install=(helm install linkerd-control-plane -n linkerd --version 1.9.3 --set-file identityTrustAnchorsPEM=/home/jason/tmp/ca/root.crt  --set-file identity.issuer.tls.crtPEM=/home/jason/tmp/ca/issuer.crt --set-file identity.issuer.tls.keyPEM=/home/jason/tmp/ca/issuer.key linkerd/linkerd-control-plane --wait)
      ## Is it a Prod cluster?
      if [[ "${c}" == "prod"* ]]
      then
        size=g4s.kube.large
        number=5
        linkerd_install+=(-f manifests/linkerd/values-ha.yaml)
        env=civo
        # linkerd_install+=(-f manifests/linkerd/overrides.yaml)
      elif [[ "${c}" == "local"* ]]
      then
        env=local
      else
        size=g4s.kube.large
        number=1
        env=civo
      fi

      case "${env}" in
        civo)
          civo k8s create "${c}" -n $number -s "${size}" -r Traefik-v2-nodeport -w || true
          civo k8s config "${c}" > ~/tmp/"${c}"
          chmod 600 ~/tmp/"${c}"
          export KUBECONFIG=~/tmp/"${c}"
          ;;
        local)
          k3d cluster delete local > /dev/null 2>&1 || true
          k3d cluster create local -s 3
          ;;
        *)
          echo "something got fucked up in the env"
          exit 1
        ;;
      esac
      ## Create Cluster
      

      ## Install Apps
      ### Linkerd
      helm install linkerd-crds linkerd/linkerd-crds \
        -n linkerd --create-namespace --wait
      "${linkerd_install[@]}"
      /home/jason/.linkerd2/bin/linkerd-stable-2.12.1 check
      
      ### BCloud

      helm install --create-namespace --namespace buoyant-cloud  --values manifests/buoyant/values.yaml --set managed=true --set metadata.agentName="${c}" --set controlPlaneOperator.extendedRBAC.enabled=true linkerd-buoyant linkerd-buoyant/linkerd-buoyant
      
      ### AES
      
      kubectl apply -f https://app.getambassador.io/yaml/edge-stack/3.1.0/aes-crds.yaml
      kubectl wait --timeout=90s --for=condition=available deployment emissary-apiext -n emissary-system
      kubectl scale -n emissary-system deployment emissary-apiext --replicas=1
      helm install -n ambassador --create-namespace edge-stack datawire/edge-stack -f manifests/ambassador/values.yaml --wait

      ### Grafana

      helm install grafana -n grafana --create-namespace grafana/grafana \
        -f https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml
      
      ### Linkerd Viz

      helm install linkerd-viz -n linkerd-viz  --set grafana.url=grafana.grafana:3000 --create-namespace linkerd/linkerd-viz --wait

      ### Apps
      
      curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | linkerd inject - | kubectl apply -f -
      kubectl create ns booksapp
      
      curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/booksapp.yml | linkerd inject - | kubectl apply -n booksapp -f -
      
      ## Create BCloud Config
      if [[ "${c}" == "prod"* ]]
      then
        helm install linkerd-multicluster -n linkerd-multicluster --create-namespace linkerd/linkerd-multicluster --wait
        helm install linkerd-jaeger -n linkerd-jaeger --create-namespace linkerd/linkerd-jaeger --wait
        kubectl -n emojivoto set env --all deploy OC_AGENT_HOST=collector.linkerd-jaeger:55678
        # kubectl apply -k github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.4.1
        # helm install linkerd-gamma --namespace linkerd-gamma --create-namespace /home/jason/git_repos/buoyant/linkerd-golang-extension/charts/linkerd-gamma
        kubectl apply -f https://raw.githubusercontent.com/fluxcd/flagger/main/artifacts/flagger/crd.yaml
        helm upgrade --install flagger flagger/flagger --namespace=linkerd-viz --set crd.create=false --set meshProvider=linkerd --set metricsServer=http://prometheus:9090
        # kubectl apply -k /home/jason/git_repos/jasonmorgan/linkerd-demos/gitops/flux/apps/source/podinfo/
        kubectl apply -f manifests/buoyant/dataplane-prod.yaml
        kubectl apply -f manifests/buoyant/controlplane-prod.yaml
      elif [[ "${c}" == "dev" || "${c}" == "test" ]]
      then
        kubectl apply -f manifests/buoyant/dataplane.yaml
        kubectl apply -f "manifests/buoyant/controlplane-${c}.yaml"
      elif [[ "${c}" == "local" ]]
      then
        kubectl apply -k github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.4.1
        helm install linkerd-gamma --namespace linkerd-gamma --create-namespace /home/jason/git_repos/buoyant/linkerd-golang-extension/charts/linkerd-gamma
        kubectl apply -f https://raw.githubusercontent.com/fluxcd/flagger/main/artifacts/flagger/crd.yaml
        helm upgrade --install flagger flagger/flagger --namespace=linkerd-viz --set crd.create=false --set meshProvider=linkerd --set metricsServer=http://prometheus:9090
        kubectl apply -k /home/jason/git_repos/jasonmorgan/linkerd-demos/gitops/flux/apps/source/podinfo/
        kubectl apply -f manifests/buoyant/dataplane-prod.yaml
        kubectl apply -f manifests/buoyant/controlplane-prod.yaml
      else
        kubectl apply -f manifests/buoyant/dataplane.yaml
        kubectl apply -f "manifests/buoyant/controlplane.yaml"
      fi

      kubectl apply -f ../linkerd-demos/policy/manifests/booksapp
      kubectl annotate ns booksapp config.linkerd.io/default-inbound-policy=deny
      kubectl rollout restart deploy -n booksapp

      ## Hack up traffic splits
      
      # kubectl annotate --overwrite crd/trafficsplits.split.smi-spec.io meta.helm.sh/release-name=linkerd-smi meta.helm.sh/release-namespace=linkerd-smi
      # kubectl label crd/trafficsplits.split.smi-spec.io   app.kubernetes.io/managed-by=Helmrd-smi --create-namespace linkerd-smi
      # helm install linkerd-smi -n linkerd-smi --create-namespace linkerd-smi/linkerd-smi

      unset KUBECONFIG
      # kubectl ctx -d "${c}" || true
    }

    # Clean out the kubeconfig
    echo "" > ~/.kube/config

    # Load up the new configs
    if [[ ! "${clusters[0]}" == "local" ]]
    then
      for c in "${clusters[@]}"
      {
        civo k8s config "${c}" -sym
        kubectl ctx "${c}"
        kubectl ns default
      }
    fi
  ;;
  stop)
    for c in "${clusters[@]}"
    {
      civo k8s delete "${c}" -y
      kubectl ctx -d "${c}" || true
    }
  ;;
  *)
    echo "missing required argument: start|stop"
    echo "./bootstrap start|stop [cluster names]"
    exit 1
  ;;
esac

