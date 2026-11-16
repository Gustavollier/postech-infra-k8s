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

# ---------------------------------------------------------------------------
# Entrada do cluster: um ingress controller, um IP público só
# ---------------------------------------------------------------------------
#
# A primeira versão tinha um LoadBalancer por serviço — quatro IPs públicos. A
# assinatura de estudante não deixou: o limite de IPs públicos por região não
# comporta os quatro mais o de saída do cluster. Com o ingress controller é um
# IP só, e o APIM roteia por caminho (/os, /billing, ...) para ele.
#
# O APIM continua sendo a única porta pública: termina o TLS, valida o JWT e
# aplica o rate limit. O ingress só distribui o que o gateway já deixou passar.

# O alvo de cada regra do ingress. ClusterIP: quem tem IP público é o
# controller, não o serviço. Mora na infra, e não no repositório do serviço,
# porque a regra do ingress precisa existir antes do primeiro deploy.
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

    type = "ClusterIP"
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 600

  set {
    name  = "controller.replicaCount"
    value = "1"
  }

  # O webhook de admissão valida os Ingress na criação. Num cluster que sobe do
  # zero ele ainda não está pronto quando o Terraform cria as regras, e o apply
  # falha. Aqui as regras são quatro e vêm deste arquivo; a validação não paga
  # a corrida.
  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Sonda de saúde do load balancer por TCP, nas duas portas.
  #
  # O padrão da Azure para uma porta HTTP é sondar com GET, e a receita comum é
  # apontar a sonda para /healthz. Aqui ela recebia 404: as regras deste
  # ingress não têm host, tomam o servidor padrão do nginx, e /healthz deixa de
  # responder. A Azure então marcava os dois nós como fora do ar e descartava
  # todo o tráfego — o APIM dava timeout em todas as rotas, com os pods
  # saudáveis. Por TCP a sonda só pergunta se a porta está aberta, que é o que
  # se quer saber do controller.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/port_80_health-probe_protocol"
    value = "Tcp"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/port_443_health-probe_protocol"
    value = "Tcp"
  }

  # Só o APIM alcança o cluster.
  #
  # Sem isto o IP do ingress respondia direto da internet, por HTTP e sem
  # token: quem o descobrisse pulava o gateway inteiro — validação do JWT e
  # rate limit. Os serviços decidem autorização a partir de um token que o
  # gateway já autenticou, então esta restrição não é enfeite: é o que
  # sustenta essa confiança. A Azure a traduz numa regra do NSG.
  set {
    name  = "controller.service.loadBalancerSourceRanges[0]"
    value = "${azurerm_api_management.main.public_ip_addresses[0]}/32"
  }

  depends_on = [azurerm_kubernetes_cluster.main]
}

# O IP do controller, que é o backend de todas as APIs de serviço no APIM.
data "kubernetes_service" "ingress" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = helm_release.ingress_nginx.namespace
  }

  depends_on = [helm_release.ingress_nginx]
}

# Uma regra por serviço. O APIM chama http://<ip>/<servico>/api/v1/...; o
# ingress casa o prefixo e entrega ao serviço só o que vem depois dele, que é
# o caminho que a aplicação conhece.
resource "kubernetes_ingress_v1" "servico" {
  for_each = local.servicos

  metadata {
    name      = each.value.app
    namespace = kubernetes_namespace.app.metadata[0].name

    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$2"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/${each.key}(/|$)(.*)"
          path_type = "ImplementationSpecific"

          backend {
            service {
              name = kubernetes_service.publico[each.key].metadata[0].name

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.ingress_nginx]
}
