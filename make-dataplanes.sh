#!/bin/bash
for i in $(kubectl get ns -o json | jq -r ".items[].metadata.name")
do
  cat >> dataplanes.yaml <<EOF
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: $i
  namespace: $i
spec:
  workloadSelector:
    matchLabels: {}
EOF
done