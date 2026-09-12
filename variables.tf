variable "resource_group_name" {
  description = "Resource group existente, o mesmo onde o APIM já está."
  type        = string
  default     = "pos-tech-fiap"
}

variable "location" {
  description = "Região do Azure."
  type        = string
  default     = "eastus"
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Nome do cluster AKS."
  type        = string
  default     = "postech-aks"
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes. Vazio usa a default da região."
  type        = string
  default     = null
}

variable "node_vm_size" {
  description = <<-EOT
    SKU das VMs do node pool.

    A subscription tem quota de apenas 4 vCPU regionais, então Standard_B2s
    (2 vCPU) com 2 nós usa exatamente o teto. Não há folga para cluster
    autoscaler — a escalabilidade é feita pelo HPA sobre os pods.
  EOT
  type        = string
  default     = "Standard_B2s"
}

variable "node_count" {
  description = "Quantidade de nós. 2 x Standard_B2s = 4 vCPU = teto da quota."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "A quota de 4 vCPU permite no máximo 2 nós Standard_B2s."
  }
}

variable "namespace" {
  description = "Namespace da aplicação no cluster."
  type        = string
  default     = "postechallenge"
}

# ---------------------------------------------------------------------------
# ACR
# ---------------------------------------------------------------------------

variable "acr_name" {
  description = "Nome do Azure Container Registry. Alfanumérico e único globalmente."
  type        = string
  default     = "postechacr13soat"
}

# ---------------------------------------------------------------------------
# APIM (recurso já existente, importado)
# ---------------------------------------------------------------------------

variable "apim_name" {
  description = "Nome do APIM já provisionado."
  type        = string
  default     = "pos-tech-fiap-apim"
}

variable "apim_publisher_name" {
  description = "Publisher do APIM. Precisa bater com o recurso existente para o import não gerar diff."
  type        = string
  default     = "pos-tech-fiap"
}

variable "apim_publisher_email" {
  description = "E-mail do publisher do APIM existente."
  type        = string
  default     = "gustavo.olier27@gmail.com"
}

variable "apim_sku" {
  description = "SKU do APIM existente."
  type        = string
  default     = "Developer_1"
}

variable "function_app_name" {
  description = "Nome do Function App de autenticação, usado como backend da rota /auth do APIM."
  type        = string
  default     = "postech-auth-fn-13soat"
}

# ---------------------------------------------------------------------------
# Integração com o banco / segredos
# ---------------------------------------------------------------------------

variable "key_vault_name" {
  description = "Key Vault criado pelo repo postech-infra-db."
  type        = string
  default     = "postech-kv-13soat"
}

# ---------------------------------------------------------------------------
# Datadog
# ---------------------------------------------------------------------------

variable "datadog_api_key" {
  description = "API key do Datadog. Injetada via TF_VAR_datadog_api_key."
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Application key do Datadog, necessária para dashboards e monitors."
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "Site do Datadog (datadoghq.com para US1, datadoghq.eu para EU)."
  type        = string
  default     = "datadoghq.com"
}

variable "datadog_api_url" {
  description = "Endpoint da API do Datadog, derivado do site."
  type        = string
  default     = "https://api.datadoghq.com/"
}

variable "datadog_alert_email" {
  description = "E-mail que recebe os alertas dos monitors."
  type        = string
  default     = "gustavo.olier27@gmail.com"
}

variable "environment" {
  description = "Valor da tag DD_ENV e sufixo dos recursos de observabilidade."
  type        = string
  default     = "production"
}

variable "tags" {
  description = "Tags aplicadas aos recursos."
  type        = map(string)
  default = {
    projeto = "postech-13soat"
    fase    = "3"
    owner   = "terraform"
  }
}
