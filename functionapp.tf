# ---------------------------------------------------------------------------
# Auth Function em Azure Container Apps — backend da rota /auth do APIM
#
# POR QUE NÃO É UM AZURE FUNCTION APP CLÁSSICO:
#
# Esta subscription tem quota ZERO para TODOS os planos de App Service testados
# — Y1 (Consumption), F1, B1, S1, P0v3, P1v3. A mensagem é sempre a mesma:
#
#   "Operation cannot be completed without additional quota.
#    Current Limit (<SKU> VMs): 0"
#
# Sem plano de App Service não existe Function App hospedado. A alternativa que
# funciona na subscription é Azure Container Apps, que é serverless de verdade
# (escala a zero, cobra por requisição) e é um destino de hospedagem oficial
# para Azure Functions.
#
# O container roda a imagem base oficial do Azure Functions: mesmo host, mesmos
# triggers e bindings, mesmo código. Muda apenas o plano de hospedagem.
#
# REGIÃO: Container Apps permite 1 ambiente por região por subscription, e o
# forwarder de logs do Datadog já ocupou East US. O ambiente vai para centralus,
# que por acaso é onde o Azure SQL está — a Function fica colocalizada com o
# banco que ela consulta.
# ---------------------------------------------------------------------------

# Storage que o host de Functions usa para estado interno.
resource "azurerm_storage_account" "function" {
  name                     = var.function_storage_name
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Identidade do Container App
#
# Ela existe como recurso próprio, e não como identidade atribuída pelo sistema,
# por causa de um impasse de ordem: o principal de uma identidade de sistema só
# passa a existir DEPOIS que o app é criado, mas o app precisa do papel AcrPull
# já na primeira revisão, para puxar a imagem. O apply ficava 20 minutos tentando
# e morria com:
#
#   ContainerAppOperationError: Failed to provision revision for container app
#   'postech-auth-fn-13soat'. Error details: Operation expired.
#
# Uma identidade atribuída pelo usuário quebra o ciclo: identidade e papel são
# criados primeiro, e o app já nasce com permissão de pull.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "auth" {
  name                = "${var.function_app_name}-id"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "auth_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.auth.principal_id
}

# A atribuição de papel não vale no mesmo instante em que a API retorna: o RBAC
# do Azure leva alguns segundos para propagar. Sem esta espera, o app pode ser
# criado numa janela em que o pull ainda é negado — e o sintoma seria de novo
# uma revisão que nunca fica pronta.
resource "time_sleep" "propagacao_acr_pull" {
  depends_on      = [azurerm_role_assignment.auth_acr_pull]
  create_duration = "60s"
}

resource "azurerm_container_app_environment" "main" {
  name                = var.container_app_environment_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.container_app_location

  tags = var.tags
}

resource "azurerm_container_app" "auth" {
  name                         = var.function_app_name
  resource_group_name          = data.azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.auth.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.auth.id
  }

  secret {
    name  = "sql-connection-string"
    value = data.azurerm_key_vault_secret.sql_connection_string.value
  }

  secret {
    name  = "jwt-secret-key"
    value = data.azurerm_key_vault_secret.jwt_secret.value
  }

  secret {
    name  = "storage-connection-string"
    value = azurerm_storage_account.function.primary_connection_string
  }

  secret {
    name  = "datadog-api-key"
    value = var.datadog_api_key
  }

  template {
    # Escala a zero quando ocioso — é o comportamento serverless que o
    # enunciado pede, e o que mantém o custo perto de zero.
    min_replicas = 0
    max_replicas = 3

    container {
      name   = "auth-function"
      image  = "${azurerm_container_registry.main.login_server}/postech-auth-function:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "FUNCTIONS_WORKER_RUNTIME"
        value = "dotnet-isolated"
      }

      env {
        name        = "AzureWebJobsStorage"
        secret_name = "storage-connection-string"
      }

      env {
        name        = "SqlConnectionString"
        secret_name = "sql-connection-string"
      }

      env {
        name        = "Jwt__SecretKey"
        secret_name = "jwt-secret-key"
      }

      env {
        name  = "Jwt__Issuer"
        value = "PosTechChallenge"
      }

      env {
        name  = "Jwt__Audience"
        value = "PosTechChallenge-API"
      }

      env {
        name  = "Jwt__ExpMinutes"
        value = "15"
      }

      env {
        name        = "DD_API_KEY"
        secret_name = "datadog-api-key"
      }

      env {
        name  = "DD_SITE"
        value = var.datadog_site
      }

      env {
        name  = "DD_ENV"
        value = var.environment
      }

      env {
        name  = "DD_SERVICE"
        value = "postech-auth-function"
      }

      # O host de Functions em container sobe em algumas dezenas de segundos, e
      # com min_replicas = 0 toda ativação paga esse custo de novo. A folga aqui
      # (30s + 5 falhas x 30s) evita que a réplica seja morta antes de responder
      # e a revisão nunca ficar pronta.
      liveness_probe {
        transport = "HTTP"
        port      = 80
        path      = "/api/health"

        initial_delay           = 30
        interval_seconds        = 30
        failure_count_threshold = 5
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 80
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      # A pipeline do repo da Function atualiza a tag da imagem a cada deploy.
      template[0].container[0].image,
    ]
  }

  depends_on = [time_sleep.propagacao_acr_pull]
}
