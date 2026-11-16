output "aks_cluster_name" {
  description = "Nome do cluster AKS."
  value       = azurerm_kubernetes_cluster.main.name
}

output "acr_login_server" {
  description = "Login server do ACR, usado pela pipeline da aplicação para push das imagens."
  value       = azurerm_container_registry.main.login_server
}

output "ip_do_ingress" {
  description = "IP público do ingress controller: o backend de todas as APIs de serviço no APIM. Só aceita conexão vinda do APIM."
  value       = data.kubernetes_service.ingress.status[0].load_balancer[0].ingress[0].ip
}

output "backends_do_apim" {
  description = "Para onde o APIM encaminha cada serviço: o IP do ingress mais o prefixo."
  value       = { for k, a in azurerm_api_management_api.servico : k => a.service_url }
}

output "rotas_no_gateway" {
  description = "A entrada de cada microsserviço no APIM."
  value       = { for k, a in azurerm_api_management_api.servico : k => "${azurerm_api_management.main.gateway_url}/${a.path}" }
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
