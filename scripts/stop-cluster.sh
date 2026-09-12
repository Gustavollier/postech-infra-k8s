#!/usr/bin/env bash
#
# Desliga o AKS para parar de consumir crédito.
#
# `az aks stop` desaloca as VMs do node pool mas preserva o cluster, os
# manifestos, os Services e o IP público do LoadBalancer. Você para de pagar
# pelos nós; o control plane do AKS é gratuito de qualquer forma.
#
# Para religar:  ./scripts/start-cluster.sh   (leva ~3-5 min)
#
# O que este script NÃO desliga, e por quê:
#   - APIM Developer  -> não pode ser parado, só deletado. É o maior custo fixo
#                        (~US$1,70/dia). Deletar custaria ~40 min para recriar.
#   - Azure SQL Basic -> ~US$0,16/dia. O tier Basic não tem auto-pause
#                        (só o serverless tem). Não compensa mexer.
#   - Function App    -> plano Consumption: ocioso custa praticamente zero.
#   - ACR Basic       -> ~US$0,17/dia, apenas armazenamento.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-pos-tech-fiap}"
CLUSTER_NAME="${CLUSTER_NAME:-postech-aks}"

ESTADO=$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --query "powerState.code" -o tsv 2>/dev/null || echo "NAO_ENCONTRADO")

case "${ESTADO}" in
  NAO_ENCONTRADO)
    echo "Cluster '${CLUSTER_NAME}' não existe no grupo '${RESOURCE_GROUP}'. Nada a fazer."
    exit 0
    ;;
  Stopped)
    echo "Cluster '${CLUSTER_NAME}' já está parado."
    exit 0
    ;;
esac

echo "==> Parando o cluster '${CLUSTER_NAME}' (leva ~3-5 min)"
az aks stop --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}"

echo
echo "Cluster parado. Os nós não consomem mais crédito."
echo "Para religar: ./scripts/start-cluster.sh"
