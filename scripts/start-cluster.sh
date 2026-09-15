#!/usr/bin/env bash
#
# Religa o AKS depois de um stop-cluster.sh.
#
# Leva ~3-5 min até os nós voltarem, e mais ~1-2 min até os pods ficarem Ready.
#
# O IP público do LoadBalancer normalmente sobrevive ao stop/start — mas
# "normalmente" não é garantia, e é dele que o APIM depende: o backend da API
# principal é o IP cru do Service, não um nome. Se o IP mudar e ninguém
# perceber, o gateway passa a responder 500 apontando para um IP morto, e o
# sintoma não diz em lugar nenhum que a causa foi o restart.
#
# Por isso este script confere, no fim, o IP do Service contra o que está
# configurado no APIM, e diz o que fazer se eles divergirem.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-pos-tech-fiap}"
CLUSTER_NAME="${CLUSTER_NAME:-postech-aks}"
NAMESPACE="${NAMESPACE:-postechallenge}"
APIM_NAME="${APIM_NAME:-pos-tech-fiap-apim}"
APIM_API_ID="${APIM_API_ID:-postechallenge-api}"

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

# ---------------------------------------------------------------------------
# O IP do Service ainda é o que o APIM conhece?
# ---------------------------------------------------------------------------
echo
echo "==> Conferindo o backend do APIM"

IP=""
for _ in $(seq 1 12); do
  IP=$(kubectl get svc postechallenge-api -n "${NAMESPACE}" \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [ -n "${IP}" ] && break
  sleep 10
done

if [ -z "${IP}" ]; then
  echo "    O Service ainda não recebeu IP. Repita em um minuto:"
  echo "    kubectl get svc postechallenge-api -n ${NAMESPACE}"
  exit 0
fi

URL_APIM=$(az apim api show \
  --resource-group "${RESOURCE_GROUP}" \
  --service-name "${APIM_NAME}" \
  --api-id "${APIM_API_ID}" \
  --query "serviceUrl" -o tsv 2>/dev/null || echo "")

echo "    LoadBalancer do cluster : ${IP}"
echo "    Backend no APIM         : ${URL_APIM:-<não foi possível ler>}"

if [ -z "${URL_APIM}" ]; then
  echo
  echo "    Não deu para ler o backend do APIM (permissão ou gateway em manutenção)."
  echo "    Confira à mão antes de considerar o ambiente de pé."
elif [ "${URL_APIM}" = "http://${IP}" ]; then
  echo
  echo "    Batem. O gateway continua apontando para o lugar certo."
else
  echo
  echo "    !! O IP MUDOU. O APIM está apontando para um endereço que não existe mais."
  echo "       Enquanto isso, toda rota de negócio no gateway vai falhar."
  echo
  echo "       Para corrigir, reaplique o Terraform deste repositório — ele lê o IP"
  echo "       do Service e reconfigura o backend:"
  echo
  echo "         terraform init && terraform apply"
  echo
  echo "       ou deixe a pipeline fazer, com um push na main."
fi

echo
echo "Lembre de despausar os dois Synthetic Tests no Datadog, se você os pausou."
