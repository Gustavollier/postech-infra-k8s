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

# O app ficou no Azure em estado Failed depois que a tentativa anterior expirou
# sem conseguir puxar a imagem, mas nunca entrou no state — o apply seguinte
# parava com "already exists - to be managed via Terraform this resource needs
# to be imported into the State".
#
# O import traz o recurso orfao, e o update seguinte aplica a configuracao certa
# (identidade atribuida pelo usuario e registry apontando para ela), o que cria
# uma revisao nova — desta vez com permissao de pull. Uma vez no state o bloco
# vira no-op e pode ser removido.
import {
  to = azurerm_container_app.auth
  id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.App/containerApps/${var.function_app_name}"
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

      # A imagem base do Functions escuta na 80, mas o valor vem do default da
      # imagem. Declarado aqui para não depender dele: se o host subir numa
      # porta diferente da de ingress, o ACA nunca considera a réplica pronta.
      env {
        name  = "ASPNETCORE_URLS"
        value = "http://+:80"
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

      # SEM liveness probe de propósito.
      #
      # A revisão falhou com "Operation expired" duas vezes: uma sem o AcrPull
      # (identidade de sistema) e outra já com o papel no lugar. Como o segundo
      # caso descarta o problema de pull, sobra o container não ficar saudável.
      # Uma probe HTTP que não responde faz o ACA reiniciar a réplica em loop até
      # o provisionamento expirar — exatamente o sintoma observado.
      #
      # Sem probe, o ACA só exige que o container suba e aceite conexão na porta
      # de ingress. Se a revisão vier saudável assim, o defeito está na rota de
      # health e não na hospedagem. Vale reintroduzir a probe depois, com o
      # caminho confirmado contra a Function rodando.
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
