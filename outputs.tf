output "aks_cluster_name" {
  description = "Nome do cluster AKS."
  value       = azurerm_kubernetes_cluster.main.name
}

output "acr_login_server" {
  description = "Login server do ACR, usado pela pipeline da aplicação para push das imagens."
  value       = azurerm_container_registry.main.login_server
}

output "app_load_balancer_ip" {
  description = "IP público do Service da aplicação. É o backend do APIM."
  value       = kubernetes_service.app.status[0].load_balancer[0].ingress[0].ip
}

output "apim_gateway_url" {
  description = "URL do gateway do APIM — é a porta de entrada pública do sistema."
  value       = azurerm_api_management.main.gateway_url
}

output "auth_endpoint" {
  description = "Endpoint público de autenticação por CPF."
  value       = "${azurerm_api_management.main.gateway_url}/auth"
}

output "namespace" {
  description = "Namespace da aplicação no cluster."
  value       = kubernetes_namespace.app.metadata[0].name
}

output "dashboard_url" {
  description = "URL do dashboard do Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.postechallenge.id}"
}
