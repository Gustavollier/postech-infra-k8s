data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.main.name
}

# Os segredos que os serviços consomem, todos lidos do Key Vault.
#
# Dois são escritos pelo postech-infra-db (as connection strings SQL e o JWT).
# Os outros são de serviços de fora da Azure — Atlas, CloudAMQP, Mercado Pago —
# e são gravados à mão no cofre, uma vez, por quem tem as contas: o valor nunca
# passa por variável, arquivo ou pipeline. Ver README, "Antes do apply".
data "azurerm_key_vault_secret" "segredo" {
  for_each = toset([
    "JwtSecretKey",
    "os-sql-connection-string",
    "identidade-sql-connection-string",
    "billing-mongo-connection-string",
    "execucao-mongo-connection-string",
    "rabbitmq-connection-string",
    "mercadopago-access-token",
  ])

  name         = each.value
  key_vault_id = data.azurerm_key_vault.main.id
}

locals {
  segredo = { for nome, s in data.azurerm_key_vault_secret.segredo : nome => s.value }

  # Os quatro microsserviços. Para cada um: o Secret que o manifesto dele
  # espera (nome e chaves batem com o k8s/deployment.yaml do repositório do
  # serviço) e o rótulo app que o Service público seleciona.
  servicos = {
    os = {
      app = "os-api"
      segredos = {
        "sql-connection-string"      = local.segredo["os-sql-connection-string"]
        "rabbitmq-connection-string" = local.segredo["rabbitmq-connection-string"]
      }
    }
    billing = {
      app = "billing-api"
      segredos = {
        "mongo-connection-string"    = local.segredo["billing-mongo-connection-string"]
        "rabbitmq-connection-string" = local.segredo["rabbitmq-connection-string"]
        "mercadopago-access-token"   = local.segredo["mercadopago-access-token"]
      }
    }
    execucao = {
      app = "execucao-api"
      segredos = {
        "mongo-connection-string"    = local.segredo["execucao-mongo-connection-string"]
        "rabbitmq-connection-string" = local.segredo["rabbitmq-connection-string"]
      }
    }
    identidade = {
      app = "identidade-api"
      segredos = {
        "sql-connection-string" = local.segredo["identidade-sql-connection-string"]
        "jwt-secret-key"        = local.segredo["JwtSecretKey"]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Azure Container Registry
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = var.tags
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_vm_size

    # Cluster autoscaler fica desligado de propósito: a quota de 4 vCPU regionais
    # não deixa espaço para um terceiro nó. A escalabilidade exigida pelo desafio
    # é entregue pelo HPA, que escala os pods de 2 para 5 dentro destes nós.
    auto_scaling_enabled = false

    upgrade_settings {
      # O AKS recusa max_surge = 0 ("maxSurge and maxUnavailable cannot both be 0")
      # e o provider azurerm não expõe max_unavailable, que seria o ajuste correto
      # para um cluster no teto da quota.
      #
      # Consequência assumida: um upgrade de versão do Kubernetes precisaria de
      # 1 nó extra (2 vCPU) que a quota de 4 vCPU não permite, e falharia. Não é
      # um problema para esta entrega, que não faz upgrade de cluster; para
      # contornar seria preciso reduzir para 1 nó antes de atualizar.
      max_surge = "1"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = var.tags
}

# Permite o AKS puxar imagens do ACR sem precisar de imagePullSecret.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Namespace e segredos da aplicação
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = "postechallenge"
    }
  }
}

resource "kubernetes_secret" "servico" {
  for_each = local.servicos

  metadata {
    name      = "${each.key}-service-secrets"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = each.value.segredos
  type = "Opaque"
}

# Um Service público por microsserviço, e o APIM roteia por caminho para o IP
# de cada um. O repositório de cada serviço tem o seu Service ClusterIP; este
# aqui é a porta de entrada, e mora na infra porque o APIM precisa do IP antes
# de o serviço subir.
#
# LoadBalancer por serviço, e não um ingress controller com um IP só, pela
# mesma razão do ADR-0003: o APIM termina o TLS e é o único cliente destes IPs,
# e a camada de ingress só somaria superfície e tempo de setup. Quatro IPs
# públicos custam centavos por dia.
resource "kubernetes_service" "publico" {
  for_each = local.servicos

  metadata {
    name      = "${each.value.app}-publico"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = {
      app = each.value.app
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "LoadBalancer"
  }

  # O IP é atribuído assim que o Service é criado, mesmo sem pods por trás.
  wait_for_load_balancer = true
}
