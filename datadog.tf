# ---------------------------------------------------------------------------
# Datadog Agent no AKS
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "datadog" {
  metadata {
    name = "datadog"
  }
}

resource "kubernetes_secret" "datadog_keys" {
  metadata {
    name      = "datadog-keys"
    namespace = kubernetes_namespace.datadog.metadata[0].name
  }

  data = {
    "api-key" = var.datadog_api_key
    "app-key" = var.datadog_app_key
  }

  type = "Opaque"
}

resource "helm_release" "datadog" {
  name       = "datadog"
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  version    = "3.72.1"
  namespace  = kubernetes_namespace.datadog.metadata[0].name

  values = [file("${path.module}/datadog-values.yaml")]

  set {
    name  = "datadog.site"
    value = var.datadog_site
  }

  set {
    name  = "datadog.apiKeyExistingSecret"
    value = kubernetes_secret.datadog_keys.metadata[0].name
  }

  set {
    name  = "datadog.appKeyExistingSecret"
    value = kubernetes_secret.datadog_keys.metadata[0].name
  }

  # O agente precisa dos nós prontos antes de subir o DaemonSet.
  depends_on = [azurerm_kubernetes_cluster.main]

  timeout = 900
}

# ---------------------------------------------------------------------------
# Dashboard — cobre os três painéis exigidos pelo enunciado
# ---------------------------------------------------------------------------

resource "datadog_dashboard" "postechallenge" {
  title       = "PosTechChallenge — Oficina Mecânica (Fase 3)"
  description = "Volume de ordens de serviço, tempo por status, erros de integração, latência das APIs e recursos do Kubernetes."
  layout_type = "ordered"

  # --- Requisito: volume diário de ordens de serviço ---
  widget {
    timeseries_definition {
      title = "Volume diário de ordens de serviço"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "count"
          }

          search_query = "service:postechallenge-api @evento:OrdemServicoCriada"

          group_by {
            facet = "@status"
            limit = 10

            sort_query {
              aggregation = "count"
              order       = "desc"
            }
          }
        }

        display_type = "bars"
      }
    }
  }

  # --- Requisito: tempo médio de execução por status ---
  widget {
    timeseries_definition {
      title = "Tempo médio de execução por status (Diagnóstico, Execução, Finalização)"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "avg"
            facet       = "@duracao_ms"
          }

          search_query = "service:postechallenge-api @evento:TransicaoStatusOrdemServico"

          group_by {
            facet = "@from_status"
            limit = 10

            sort_query {
              aggregation = "avg"
              facet       = "@duracao_ms"
              order       = "desc"
            }
          }
        }

        display_type = "line"
      }
    }
  }

  # --- Requisito: erros e falhas nas integrações ---
  widget {
    timeseries_definition {
      title = "Erros e falhas nas integrações"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "count"
          }

          search_query = "service:postechallenge-api status:error"

          group_by {
            facet = "@evento"
            limit = 10

            sort_query {
              aggregation = "count"
              order       = "desc"
            }
          }
        }

        display_type = "bars"
      }
    }
  }

  # --- Requisito: latência das APIs ---
  widget {
    timeseries_definition {
      title = "Latência das APIs (p50 / p95 / p99)"

      request {
        q            = "p50:trace.aspnet_core.request{service:postechallenge-api}"
        display_type = "line"
      }

      request {
        q            = "p95:trace.aspnet_core.request{service:postechallenge-api}"
        display_type = "line"
      }

      request {
        q            = "p99:trace.aspnet_core.request{service:postechallenge-api}"
        display_type = "line"
      }
    }
  }

  # --- Requisito: consumo de recursos do Kubernetes ---
  widget {
    timeseries_definition {
      title = "Kubernetes — CPU por pod"

      request {
        q            = "avg:kubernetes.cpu.usage.total{kube_namespace:${var.namespace}} by {pod_name}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Kubernetes — memória por pod"

      request {
        q            = "avg:kubernetes.memory.usage{kube_namespace:${var.namespace}} by {pod_name}"
        display_type = "line"
      }
    }
  }

  # --- Escalabilidade: o HPA em ação ---
  widget {
    timeseries_definition {
      title = "Réplicas em execução (HPA)"

      request {
        q            = "max:kubernetes_state.deployment.replicas_available{kube_namespace:${var.namespace}}"
        display_type = "area"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Monitors — alertas exigidos pelo enunciado
# ---------------------------------------------------------------------------

# Requisito explícito: "Alertas para falhas no processamento de ordens de serviço".
resource "datadog_monitor" "falha_processamento_os" {
  name    = "[PosTech] Falha no processamento de ordens de serviço"
  type    = "log alert"
  message = <<-EOT
    Falhas no processamento de ordens de serviço detectadas nos últimos 5 minutos.

    Verifique os logs com o correlationId do evento para rastrear a requisição
    da entrada no APIM até o erro na aplicação.

    @${var.datadog_alert_email}
  EOT

  query = "logs(\"service:postechallenge-api status:error @evento:FalhaProcessamentoOrdemServico\").index(\"*\").rollup(\"count\").last(\"5m\") > 3"

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  notify_no_data = false
  tags           = ["projeto:postech-13soat", "env:${var.environment}"]
}

resource "datadog_monitor" "latencia_alta" {
  name    = "[PosTech] Latência p95 acima de 1s"
  type    = "query alert"
  message = <<-EOT
    A latência p95 da API passou de 1 segundo.

    Verifique no dashboard se o HPA já escalou os pods e se o Azure SQL
    não está com DTU saturada.

    @${var.datadog_alert_email}
  EOT

  query = "avg(last_10m):p95:trace.aspnet_core.request{service:postechallenge-api} > 1"

  monitor_thresholds {
    critical = 1
    warning  = 0.5
  }

  notify_no_data = false
  tags           = ["projeto:postech-13soat", "env:${var.environment}"]
}

resource "datadog_monitor" "taxa_erro_5xx" {
  name    = "[PosTech] Taxa de erros 5xx elevada"
  type    = "log alert"
  message = <<-EOT
    Volume anormal de respostas 5xx na API.

    @${var.datadog_alert_email}
  EOT

  query = "logs(\"service:postechallenge-api @http.status_code:[500 TO 599]\").index(\"*\").rollup(\"count\").last(\"5m\") > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data = false
  tags           = ["projeto:postech-13soat", "env:${var.environment}"]
}

# ---------------------------------------------------------------------------
# Synthetics — requisito de "healthchecks e uptime"
# ---------------------------------------------------------------------------

resource "datadog_synthetics_test" "health_api" {
  name      = "[PosTech] Uptime da API via APIM"
  type      = "api"
  subtype   = "http"
  status    = "live"
  locations = ["aws:us-east-1"]
  message   = "A API não respondeu ao health check via APIM. @${var.datadog_alert_email}"
  tags      = ["projeto:postech-13soat", "env:${var.environment}"]

  request_definition {
    method = "GET"
    url    = "https://${azurerm_api_management.main.name}.azure-api.net/health"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "3000"
  }

  options_list {
    tick_every           = 300
    min_failure_duration = 300
    min_location_failed  = 1
  }
}

resource "datadog_synthetics_test" "health_function" {
  name      = "[PosTech] Uptime da Auth Function"
  type      = "api"
  subtype   = "http"
  status    = "live"
  locations = ["aws:us-east-1"]
  message   = "A Auth Function não respondeu ao health check. @${var.datadog_alert_email}"
  tags      = ["projeto:postech-13soat", "env:${var.environment}"]

  request_definition {
    method = "GET"
    url    = "https://${azurerm_api_management.main.name}.azure-api.net/auth/health"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  options_list {
    tick_every           = 300
    min_failure_duration = 300
    min_location_failed  = 1
  }
}
