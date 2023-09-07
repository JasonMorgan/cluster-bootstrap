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
    if [ -z "${KUBECONFIG}" ]
    then
      export KUBECONFIG=~/.kube/config
    fi

    ## Begin our creationloop
    for c in "${clusters[@]}"
    {
      ## Is it a Prod cluster?
      if [[ "${c}" == "prod"* ]]
      then
        size=g4s.kube.large
        number=5
        env=civo
        # linkerd_install+=(-f manifests/linkerd/overrides.yaml)

      ## Is it local?
      elif [[ "${c}" == "local"* ]]
      then
        env=local

      ## Whatever else it may be
      else
        size=g4s.kube.large
        number=1
        env=civo
      fi

      ## Cluster creation
      case "${env}" in
        civo)
          kubectl ctx -u
          kubectl config delete-context "${c}" || true
          kubectl config delete-cluster "${c}" || true
          kubectl config delete-user "${c}" || true
          civo k8s create "${c}" -n $number -s "${size}" -r Traefik-v2-nodeport -w # || true
          civo k8s config -sym "${c}" || true
          # sleep 60
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
    }

    PROVISION=1
  ;;
  stop)
    for c in "${clusters[@]}"
    {
      civo k8s delete "${c}" -y
      kubectl config delete-context "${c}" || true
      kubectl config delete-cluster "${c}" || true
      kubectl config delete-user "${c}" || true
    }
  ;;
  provision)
    PROVISION=1
  ;;
  *)
    echo "missing required argument: start|stop|provision"
    echo "./bootstrap start|stop [cluster names]"
    exit 1
  ;;
esac

if [[ $PROVISION == 1 ]]
then
  ## Begin our provisioning loop
  for c in "${clusters[@]}"
  {
    ## Set context
    civo k8s config "${c}" -sym
    kubectl ctx "${c}"
    kubectl ns default

    flux install

    ## Install Apps
    ### Cert-Manager
    # helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true --version v1.10.0 --wait
    # helm upgrade --install --namespace cert-manager cert-manager-trust jetstack/cert-manager-trust --wait
    kubectl create ns linkerd
    case "${c}" in
      prod*)
        #kubectl apply -f manifests/cert-manager/bootstrap_ca.prod.yaml
        ;;
      dev)
        #kubectl apply -f manifests/cert-manager/bootstrap_ca.dev.yaml
        ;;
      *)
        #kubectl apply -f manifests/cert-manager/bootstrap_ca.test.yaml
        ;;
    esac


    ### Linkerd
    helm install linkerd-crds linkerd/linkerd-crds \
      -n linkerd --wait
    "${linkerd_install[@]}"
    /home/jason/.linkerd2/bin/linkerd-stable-2.12.1 check
    
    ### BCloud

    helm install --create-namespace --namespace buoyant-cloud  --values manifests/buoyant/values.yaml --set managed=true --set metadata.agentName="${c}" linkerd-buoyant linkerd-buoyant/linkerd-buoyant
    
    ### AES
    
    kubectl apply -f https://app.getambassador.io/yaml/edge-stack/3.1.0/aes-crds.yaml
    kubectl wait --timeout=90s --for=condition=available deployment emissary-apiext -n emissary-system
    kubectl scale -n emissary-system deployment emissary-apiext --replicas=1
    helm install -n ambassador --create-namespace edge-stack datawire/edge-stack -f manifests/ambassador/values.yaml --wait

    ### Apps
    
    curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | linkerd inject - | kubectl apply -f -

    kubectl create ns booksapp
    curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/booksapp.yml | linkerd inject - | kubectl apply -n booksapp -f -
    
    ## Create BCloud Config
    if [[ "${c}" == "prod"* ]]
    then
      ### Grafana

      helm install grafana -n grafana --create-namespace grafana/grafana \
      -f https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml
    
      ### Linkerd Viz

      helm install linkerd-viz -n linkerd-viz  --set grafana.url=grafana.grafana:3000 --create-namespace linkerd/linkerd-viz --wait
      
      ### Linkerd smi

      helm install linkerd-smi -n linkerd-smi --create-namespace linkerd-smi/linkerd-smi --wait

      ### Linkerd Multicluster

      helm install linkerd-multicluster -n linkerd-multicluster --create-namespace linkerd/linkerd-multicluster --wait
      
      ### Linkerd Jaeger
      helm install linkerd-jaeger -n linkerd-jaeger --create-namespace linkerd/linkerd-jaeger --wait
      
      kubectl -n emojivoto set env --all deploy OC_AGENT_HOST=collector.linkerd-jaeger:55678
      
      ### Install Flagger
      # kubectl apply -f https://raw.githubusercontent.com/fluxcd/flagger/main/artifacts/flagger/crd.yaml
      # helm upgrade --install flagger flagger/flagger --namespace=linkerd-viz --set crd.create=false --set meshProvider=linkerd --set metricsServer=http://prometheus:9090
      
      ### BCloud Manifests
      kubectl apply -f manifests/buoyant/dataplane-prod.yaml
      kubectl apply -f manifests/buoyant/controlplane-prod.yaml

    elif [[ "${c}" == "dev" || "${c}" == "test" ]]
    then
      ### BCloud Manifests
      kubectl apply -f manifests/buoyant/dataplane.yaml
      kubectl apply -f "manifests/buoyant/controlplane-${c}.yaml" || true

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

    ## Apply policy objects
    kubectl apply -f manifests/booksapp
    kubectl apply -f manifests/emojivoto
    kubectl annotate ns booksapp config.linkerd.io/default-inbound-policy=deny
    kubectl rollout restart deploy -n booksapp
  }
fi