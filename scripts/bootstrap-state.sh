#!/usr/bin/env bash
#
# Cria o Storage Account que guarda o state remoto do Terraform.
#
# Isto roda UMA vez, antes do primeiro `terraform init` de qualquer repo de infra.
# O state não pode morar num backend gerenciado pelo próprio Terraform — é o
# clássico problema do ovo e da galinha —, então este passo é imperativo de propósito.
#
# Uso:  ./scripts/bootstrap-state.sh
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-pos-tech-fiap}"
LOCATION="${LOCATION:-eastus}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-postechtfstate13soat}"
CONTAINER="${CONTAINER:-tfstate}"

echo "==> Assinatura em uso"
az account show --query "{nome:name, id:id}" -o table

echo
echo "==> Garantindo o resource group '${RESOURCE_GROUP}'"
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --output none
echo "    ok"

echo
echo "==> Criando o storage account '${STORAGE_ACCOUNT}'"
if az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" &>/dev/null; then
  echo "    já existe, seguindo"
else
  az storage account create \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none
  echo "    criado"
fi

echo
echo "==> Habilitando versionamento do blob (permite recuperar um state corrompido)"
az storage account blob-service-properties update \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --enable-versioning true \
  --output none
echo "    ok"

echo
echo "==> Criando o container '${CONTAINER}'"
az storage container create \
  --name "${CONTAINER}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none
echo "    ok"

cat <<EOF

------------------------------------------------------------------
State remoto pronto.

  resource_group_name  = "${RESOURCE_GROUP}"
  storage_account_name = "${STORAGE_ACCOUNT}"
  container_name       = "${CONTAINER}"

Os blocos backend "azurerm" dos repos de infra já apontam para cá.
Agora rode 'terraform init' em cada repo de infra.
------------------------------------------------------------------
EOF
