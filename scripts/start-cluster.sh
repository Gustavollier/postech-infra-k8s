#!/usr/bin/env bash
#
# Religa o AKS depois de um stop-cluster.sh.
#
# Leva ~3-5 min até os nós voltarem, e mais ~1-2 min até os pods ficarem Ready.
# O IP do LoadBalancer é preservado, então o backend configurado no APIM
# continua válido — não é preciso reaplicar o Terraform.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-pos-tech-fiap}"
CLUSTER_NAME="${CLUSTER_NAME:-postech-aks}"
NAMESPACE="${NAMESPACE:-postechallenge}"

ESTADO=$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --query "powerState.code" -o tsv 2>/dev/null || echo "NAO_ENCONTRADO")

if [ "${ESTADO}" = "NAO_ENCONTRADO" ]; then
  echo "Cluster '${CLUSTER_NAME}' não existe. Rode o terraform apply primeiro."
  exit 1
fi

if [ "${ESTADO}" = "Running" ]; then
  echo "Cluster '${CLUSTER_NAME}' já está rodando."
else
  echo "==> Iniciando o cluster '${CLUSTER_NAME}' (leva ~3-5 min)"
  az aks start --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}"
fi

echo
echo "==> Atualizando o kubeconfig"
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing

echo
echo "==> Aguardando os pods da aplicação ficarem Ready"
kubectl wait --for=condition=Ready pods \
  --all \
  --namespace "${NAMESPACE}" \
  --timeout=300s || echo "    (alguns pods ainda subindo — verifique com kubectl get pods -n ${NAMESPACE})"

echo
kubectl get pods,svc,hpa --namespace "${NAMESPACE}"

IP=$(kubectl get svc postechallenge-api -n "${NAMESPACE}" \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "${IP}" ]; then
  echo
  echo "LoadBalancer: ${IP}  (backend configurado no APIM)"
fi
