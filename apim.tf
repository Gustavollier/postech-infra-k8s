# ---------------------------------------------------------------------------
# API Management
#
# O APIM já foi provisionado manualmente no portal. Recriar um Developer SKU leva
# ~40 minutos, então o recurso é IMPORTADO para o state em vez de recriado.
# Os atributos abaixo espelham o recurso existente para o import não gerar diff.
# ---------------------------------------------------------------------------

import {
  to = azurerm_api_management.main
  id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.ApiManagement/service/${var.apim_name}"
}

data "azurerm_client_config" "current" {}

resource "azurerm_api_management" "main" {
  name                = var.apim_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  tags = var.tags

  lifecycle {
    # O APIM está no state por import. Sem esta trava, um `terraform destroy`
    # para economizar custo apagaria o serviço — e recriar um Developer SKU
    # leva ~40 minutos, tempo que não temos. Para desligar e economizar, use
    # scripts/stop-cluster.sh (para o AKS), que é onde está o custo variável.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Named values
# ---------------------------------------------------------------------------

# A policy validate-jwt espera a chave simétrica em base64, não o texto puro.
resource "azurerm_api_management_named_value" "jwt_signing_key" {
  name                = "jwt-signing-key"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  display_name        = "jwt-signing-key"
  value               = base64encode(data.azurerm_key_vault_secret.jwt_secret.value)
  secret              = true
}

# ---------------------------------------------------------------------------
# API da aplicação — backend é o LoadBalancer do AKS
# ---------------------------------------------------------------------------

resource "azurerm_api_management_api" "app" {
  name                = "postechallenge-api"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  revision            = "1"
  display_name        = "PosTechChallenge — Oficina Mecânica API"
  protocols           = ["https"]

  # path vazio deixa as rotas como https://<gateway>/api/v1/... , iguais às do spec.
  path = ""

  service_url = "http://${kubernetes_service.app.status[0].load_balancer[0].ingress[0].ip}"

  import {
    content_format = "openapi+json"
    content_value  = file("${path.module}/openapi/postechallenge.json")
  }
}

resource "azurerm_api_management_api_policy" "app" {
  api_name            = azurerm_api_management_api.app.name
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name

  xml_content = file("${path.module}/policies/app-api.xml")

  depends_on = [azurerm_api_management_named_value.jwt_signing_key]
}

# ---------------------------------------------------------------------------
# API de autenticação — backend é a Azure Function
# ---------------------------------------------------------------------------

resource "azurerm_api_management_api" "auth" {
  name                = "postechallenge-auth"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  revision            = "1"
  display_name        = "PosTechChallenge — Autenticação por CPF"
  protocols           = ["https"]
  path                = "auth"

  service_url = "https://${var.function_app_name}.azurewebsites.net/api"
}

resource "azurerm_api_management_api_operation" "auth_post" {
  operation_id        = "auth-cpf"
  api_name            = azurerm_api_management_api.auth.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = data.azurerm_resource_group.main.name
  display_name        = "Autenticar cliente por CPF"
  method              = "POST"
  url_template        = "/"
  description         = "Valida o CPF, confirma o cliente na base e devolve um JWT."

  response {
    status_code = 200
    description = "Token emitido"
  }

  response {
    status_code = 400
    description = "CPF inválido"
  }

  response {
    status_code = 403
    description = "Cliente inativo"
  }

  response {
    status_code = 404
    description = "Cliente não encontrado"
  }
}

resource "azurerm_api_management_api_operation" "auth_health" {
  operation_id        = "auth-health"
  api_name            = azurerm_api_management_api.auth.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = data.azurerm_resource_group.main.name
  display_name        = "Health check da Function"
  method              = "GET"
  url_template        = "/health"

  response {
    status_code = 200
    description = "Function saudável"
  }
}

# A rota de autenticação é pública por definição — quem chama ainda não tem token.
# A proteção aqui é rate limit, para não virar vetor de enumeração de CPF.
resource "azurerm_api_management_api_policy" "auth" {
  api_name            = azurerm_api_management_api.auth.name
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name

  xml_content = file("${path.module}/policies/auth-api.xml")
}

# ---------------------------------------------------------------------------
# Diagnóstico → Log Analytics (o forwarder do Datadog consome daqui)
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "main" {
  name                = "postech-logs"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "apim-para-datadog"
  target_resource_id         = azurerm_api_management.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
