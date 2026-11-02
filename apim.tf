# ---------------------------------------------------------------------------
# API Management
#
# Fase 4: o APIM é criado pelo Terraform, e não mais importado. Na Fase 3 ele
# tinha sido feito à mão no portal, e o state o trazia por import com
# prevent_destroy, porque recriar um Developer leva ~40 minutos. Agora a
# assinatura é recriada do zero perto da gravação e destruída depois, então o
# destroy tem que funcionar e não há nada a importar.
#
# O tier é escolhido por var.apim_sku. O Consumption é cobrado por chamada e
# sobe em minutos, mas não tem rate-limit-by-key nem logs de recurso no Azure
# Monitor; as políticas e o diagnóstico abaixo se ajustam a ele sozinhos.
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

locals {
  apim_consumption = startswith(var.apim_sku, "Consumption")

  # Uma API por microsserviço. O caminho é o prefixo no gateway:
  # https://<apim>.azure-api.net/os/api/v1/ordens-servico chega no OS Service
  # como /api/v1/ordens-servico.
  apis = {
    os = {
      nome     = "Ordem de Serviço"
      publicas = ["/health"]
    }
    billing = {
      nome = "Orçamento e Pagamento"
      # Quem chama o webhook é o Mercado Pago, que não tem o nosso token. O
      # serviço não confia na notificação: consulta o adquirente antes de agir.
      publicas = ["/health", "/pagamentos/webhook"]
    }
    execucao = {
      nome     = "Execução e Produção"
      publicas = ["/health"]
    }
    identidade = {
      nome = "Identidade"
      # Login e troca de senha: quem chama ainda não tem token. O serviço tem
      # bloqueio por tentativas, e a troca de senha passa pelo mesmo login.
      publicas = ["/health", "/autenticacao/login", "/autenticacao/trocar-senha"]
    }
  }

  # O APIM não repassa o que não casa com uma operação. Uma operação curinga
  # por método deixa todas as rotas do serviço passarem, e o contrato de cada
  # uma fica no Swagger do próprio serviço, que é onde ele é mantido.
  metodos = ["GET", "POST", "PUT", "PATCH", "DELETE"]

  operacoes = {
    for par in setproduct(keys(local.apis), local.metodos) :
    "${par[0]}-${lower(par[1])}" => { api = par[0], metodo = par[1] }
  }
}

resource "azurerm_api_management" "main" {
  name                = var.apim_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  tags = var.tags
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
  value               = base64encode(local.segredo["JwtSecretKey"])
  secret              = true
}

# ---------------------------------------------------------------------------
# Uma API por microsserviço — backend é o Service público de cada um no AKS
# ---------------------------------------------------------------------------

resource "azurerm_api_management_api" "servico" {
  for_each = local.apis

  name                = "postech-${each.key}"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  revision            = "1"
  display_name        = "PosTech — ${each.value.nome}"
  protocols           = ["https"]
  path                = each.key

  # A autenticação é por JWT, não por chave de subscription do APIM.
  subscription_required = false

  service_url = "http://${kubernetes_service.publico[each.key].status[0].load_balancer[0].ingress[0].ip}"
}

resource "azurerm_api_management_api_operation" "curinga" {
  for_each = local.operacoes

  operation_id        = each.key
  api_name            = azurerm_api_management_api.servico[each.value.api].name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = data.azurerm_resource_group.main.name
  display_name        = "${each.value.metodo} /*"
  method              = each.value.metodo
  url_template        = "/*"
}

resource "azurerm_api_management_api_policy" "servico" {
  for_each = local.apis

  api_name            = azurerm_api_management_api.servico[each.key].name
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name

  xml_content = templatefile("${path.module}/policies/servico-api.xml.tftpl", {
    publicas = each.value.publicas
    prefixo  = each.key
    limitar  = !local.apim_consumption
  })

  depends_on = [azurerm_api_management_named_value.jwt_signing_key]
}

# ---------------------------------------------------------------------------
# API de autenticação — backend é a Azure Function
# ---------------------------------------------------------------------------

resource "azurerm_api_management_api" "auth" {
  name                  = "postechallenge-auth"
  resource_group_name   = data.azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "PosTechChallenge — Autenticação por CPF"
  protocols             = ["https"]
  path                  = "auth"
  subscription_required = false

  # A Function roda em Container Apps, não em Function App — ver functionapp.tf
  # para o motivo (quota zero de App Service nesta subscription).
  service_url = "https://${azurerm_container_app.auth.ingress[0].fqdn}/api"
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

  xml_content = templatefile("${path.module}/policies/auth-api.xml.tftpl", {
    limitar = !local.apim_consumption
  })
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

# O Consumption não exporta logs de recurso para o Azure Monitor: no tier
# Consumption este diagnóstico não existe, e o tráfego do gateway só aparece
# no Datadog pelos traces dos serviços.
resource "azurerm_monitor_diagnostic_setting" "apim" {
  count = local.apim_consumption ? 0 : 1

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
