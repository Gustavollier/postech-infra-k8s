#!/usr/bin/env bash
#
# Remove infraestrutura para parar de gastar. Três níveis, do reversível ao definitivo.
#
# Uso:  ./scripts/teardown.sh <nivel>
#
#   1  pausar    Para o AKS. Reversível em ~5 min, preserva tudo. (= stop-cluster.sh)
#   2  compute   Destrói AKS + ACR + Log Analytics via Terraform.
#                PRESERVA o APIM e o banco (ambos com prevent_destroy).
#                Recriar leva ~15 min de terraform apply.
#   3  tudo      Apaga os dois resource groups inteiros, APIM incluído.
#                DEFINITIVO. Recriar o APIM Developer leva ~40 min.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-pos-tech-fiap}"
CLUSTER_NAME="${CLUSTER_NAME:-postech-aks}"
NIVEL="${1:-}"

confirmar() {
  local mensagem="$1" esperado="$2" resposta
  echo
  echo "!! ${mensagem}"
  printf "   Digite '%s' para confirmar: " "${esperado}"
  read -r resposta
  if [ "${resposta}" != "${esperado}" ]; then
    echo "   Cancelado."
    exit 1
  fi
}

case "${NIVEL}" in
  1|pausar)
    exec "$(dirname "$0")/stop-cluster.sh"
    ;;

  2|compute)
    confirmar "Isto destrói o AKS, o ACR e o Log Analytics. APIM e banco permanecem." "destruir"
    echo
    echo "==> terraform destroy no compute"
    terraform destroy \
      -target=helm_release.datadog \
      -target=kubernetes_service.app \
      -target=kubernetes_secret.app \
      -target=kubernetes_secret.datadog_keys \
      -target=kubernetes_namespace.app \
      -target=kubernetes_namespace.datadog \
      -target=azurerm_kubernetes_cluster.main \
      -target=azurerm_container_registry.main \
      -target=azurerm_log_analytics_workspace.main
    echo
    echo "Compute removido. APIM e banco intactos."
    echo "Para recriar: terraform apply"
    ;;

  3|tudo)
    confirmar "Isto apaga TUDO, incluindo o APIM (~40 min para recriar) e o banco com os dados." "apagar tudo"
    echo
    echo "==> Apagando o resource group '${RESOURCE_GROUP}'"
    az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
    echo "==> Apagando o resource group 'datadog-log-forwarding'"
    az group delete --name "datadog-log-forwarding" --yes --no-wait || true
    echo
    echo "Exclusão disparada em background. Acompanhe com:"
    echo "  az group list -o table"
    echo
    echo "Lembre-se de remover o state remoto se não for mais usar:"
    echo "  o storage account postechtfstate13soat está no grupo apagado."
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
