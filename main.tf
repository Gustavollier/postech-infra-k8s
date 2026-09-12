data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azurerm_key_vault_secret" "sql_connection_string" {
  name         = "SqlConnectionString"
  key_vault_id = data.azurerm_key_vault.main.id
}

data "azurerm_key_vault_secret" "jwt_secret" {
  name         = "JwtSecretKey"
  key_vault_id = data.azurerm_key_vault.main.id
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
      # Com a quota no teto, um surge de 33% não teria onde alocar o nó extra.
      max_surge = "0"
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

resource "kubernetes_secret" "app" {
  metadata {
    name      = "postechallenge-secrets"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    "ConnectionStrings__DefaultConnection" = data.azurerm_key_vault_secret.sql_connection_string.value
    "Jwt__SecretKey"                       = data.azurerm_key_vault_secret.jwt_secret.value
  }

  type = "Opaque"
}

# O Service é o ponto de entrada do cluster, então mora no repo de infra: o APIM
# precisa do IP dele como backend, e ele tem que existir antes do app subir.
# O Deployment e o HPA ficam no repo da aplicação.
#
# Optamos por LoadBalancer em vez de ingress-nginx + cert-manager: o APIM já
# termina o TLS e é o único cliente deste IP, então a camada extra de ingress
# só adicionaria superfície e tempo de setup. Registrado no ADR-0003.
resource "kubernetes_service" "app" {
  metadata {
    name      = "postechallenge-api"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = {
      app = "postechallenge-api"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "LoadBalancer"
  }

  # O IP é atribuído pelo Azure assim que o Service é criado, mesmo sem pods
  # por trás. O APIM usa esse IP como backend.
  wait_for_load_balancer = true
}
