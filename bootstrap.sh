#!/bin/bash
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
    ## Add repos

    helm repo add linkerd-buoyant https://helm.buoyant.cloud
    helm repo add linkerd https://helm.linkerd.io/stable
    helm repo add flagger https://flagger.app
    helm repo add jetstack https://charts.jetstack.io
    helm repo add linkerd-smi https://linkerd.github.io/linkerd-smi
    helm repo add datawire https://app.getambassador.io
    helm repo add grafana https://grafana.github.io/helm-charts

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
          kubectl config delete-context "${c}"  &> /dev/null || true
          kubectl config delete-cluster "${c}"  &> /dev/null || true
          kubectl config delete-user "${c}"  &> /dev/null || true
          civo k8s create "${c}" -n $number -s "${size}" -r Traefik-v2-nodeport -w # || true
          civo k8s config -sy "${c}" || true
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
    civo k8s config "${c}" -sy
    kubectl ctx "${c}"
    kubectl ns default

    ## Ready helm repos
    helm repo update > /dev/null
    
    ## Install Apps
    ### Cert-Manager
    helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --version v1.12.0 --create-namespace --set installCRDs=true --wait
    kubectl create ns linkerd || true
    kubectl create ns linkerd-buoyant || true
    kubectl apply -f secrets/buoyant-registry-secret.yaml
    case "${c}" in
      prod*)
        kubectl create secret tls linkerd-trust-anchor \
          --cert=secrets/ca.prod.crt \
          --key=secrets/ca.prod.key \
          --namespace=linkerd || true
        kubectl apply -f manifests/cert-manager/bootstrap_ca.prod.yaml
        linkerd_install+=(--set-file identityTrustAnchorsPEM=secrets/ca.prod.crt)
        linkerd_install+=(-f manifests/linkerd/values-ha.yaml)
        ;;
      dev)
        kubectl create secret tls linkerd-trust-anchor \
          --cert=secrets/ca.dev.crt \
          --key=secrets/ca.dev.key \
          --namespace=linkerd || true
        kubectl apply -f manifests/cert-manager/bootstrap_ca.dev.yaml
        linkerd_install+=(--set-file identityTrustAnchorsPEM=secrets/ca.dev.crt)
        ;;
      *)
        kubectl create secret tls linkerd-trust-anchor \
          --cert=secrets/ca.test.crt \
          --key=secrets/ca.test.key \
          --namespace=linkerd || true
        kubectl apply -f manifests/cert-manager/bootstrap_ca.test.yaml
        linkerd_install+=(--set-file identityTrustAnchorsPEM=secrets/ca.test.crt)
        ;;
    esac
    
    ### Apps
    kubectl create ns emojivoto || true
    kubectl create ns booksapp || true
    kubectl create ns ambassador || true
    

    ### BCloud

    helm upgrade -i linkerd-buoyant \
      --namespace linkerd-buoyant \
      --set controlPlaneOperator.helmDockerConfigJSONSecret=buoyant-registry-secret \
      --set metadata.agentName="${c}" \
      --values manifests/buoyant/values.yaml \
    linkerd-buoyant/linkerd-buoyant
    
    ### Linkerd

    case "${c}" in
      prod*)
        kubectl apply -f manifests/buoyant/controlplane-prod.yaml
        kubectl apply -f manifests/buoyant/buoyant-cloud-agent.yaml
        kubectl apply -f manifests/buoyant/dataplane.yaml
        ;;
      dev)
        kubectl apply -f manifests/buoyant/controlplane-dev.yaml
        kubectl apply -f manifests/buoyant/dataplane.yaml
        ;;
      *)
        kubectl apply -f manifests/buoyant/controlplane-test.yaml
        kubectl apply -f manifests/buoyant/dataplane.yaml
        ;;
    esac
    sleep 120
    kubectl wait --for=condition=available deployment linkerd-control-plane-validator -n linkerd-buoyant
    kubectl wait --for=condition=available deployment linkerd-control-plane-operator -n linkerd-buoyant
    linkerd check

    ### Install Apps
    curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | linkerd inject - | kubectl apply -f -
    curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/booksapp.yml | linkerd inject - | kubectl apply -n booksapp -f -

    ### AES
    
    kubectl apply -f https://app.getambassador.io/yaml/edge-stack/3.8.0/aes-crds.yaml
    kubectl wait --timeout=90s --for=condition=available deployment emissary-apiext -n emissary-system
    kubectl scale -n emissary-system deployment emissary-apiext --replicas=1
    helm upgrade -i -n ambassador edge-stack datawire/edge-stack -f manifests/ambassador/values.yaml -f secrets/aes.yaml --wait

    
    
    ## Create BCloud Config
    if [[ "${c}" == "prod"* ]]
    then
      ### Grafana

      helm upgrade -i grafana -n grafana --create-namespace grafana/grafana \
      -f https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml
    
      ### Linkerd Viz

      helm upgrade -i linkerd-viz -n linkerd-viz  --set grafana.url=grafana.grafana:3000 --create-namespace linkerd/linkerd-viz --wait
      
      ### Linkerd smi

      helm upgrade -i linkerd-smi -n linkerd-smi --create-namespace linkerd-smi/linkerd-smi --wait

      ### Linkerd Multicluster

      helm upgrade -i linkerd-multicluster -n linkerd-multicluster --create-namespace linkerd/linkerd-multicluster --wait
      
      ### Linkerd Jaeger
      helm upgrade -i linkerd-jaeger -n linkerd-jaeger --create-namespace linkerd/linkerd-jaeger --wait
      
      kubectl -n emojivoto set env --all deploy OC_AGENT_HOST=collector.linkerd-jaeger:55678
      
      ### Install Flagger
      kubectl apply -f https://raw.githubusercontent.com/fluxcd/flagger/main/artifacts/flagger/crd.yaml
      helm upgrade --install flagger flagger/flagger --namespace=linkerd-viz --set crd.create=false --set linkerdAuthPolicy.create=true --set meshProvider=linkerd --set metricsServer=http://prometheus:9090

      kubectl apply -f manifests/buoyant/dataplane-prod.yaml
    fi
    ## Apply policy objects
    kubectl apply -f manifests/booksapp
    kubectl apply -f manifests/emojivoto
    kubectl annotate ns booksapp config.linkerd.io/default-inbound-policy=deny
    kubectl rollout restart deploy -n booksapp
  }
fi