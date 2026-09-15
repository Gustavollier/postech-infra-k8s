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
#   - Auth Function   -> roda em Container Apps com min_replicas = 0. Sem
#                        trafego nao ha replica, e sem replica nao ha custo.
#                        Ela continua no ar e responde normalmente.
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
echo
echo "----------------------------------------------------------------------"
echo "Duas coisas para fazer agora, senão o ambiente parado dá trabalho:"
echo
echo "1) Pause os dois Synthetic Tests no Datadog."
echo "   Eles batem no /health a cada 5 min e mandam e-mail quando falham —"
echo "   com o cluster parado, vão falhar para sempre."
echo "   app.datadoghq.com -> Digital Experience -> Synthetic Tests"
echo "   -> selecione '[PosTech] Uptime da API via APIM' e"
echo "      '[PosTech] Uptime da Auth Function' -> Pause"
echo "   (o proximo terraform apply volta os dois para live sozinho, porque"
echo "    status = \"live\" esta declarado no datadog.tf — nao precisa desfazer)"
echo
echo "2) Nao empurre nada para main nem para develop enquanto estiver parado."
echo "   As pipelines dos dois repositorios fazem deploy/apply contra o cluster"
echo "   e vao falhar: o CI/CD da aplicacao nao consegue fazer rollout, e o"
echo "   terraform nem termina o refresh, porque os recursos kubernetes_* e o"
echo "   helm_release nao alcancam o API server. Trabalhe em branch e segure o"
echo "   merge — ou religue o cluster antes de mergear."
echo "----------------------------------------------------------------------"
echo
echo "Para religar: ./scripts/start-cluster.sh   (~5 min, confere o IP no fim)"
