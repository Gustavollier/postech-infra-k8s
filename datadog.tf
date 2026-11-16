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
  title       = "PosTechChallenge — Oficina Mecânica (Fase 4)"
  description = "Ordens em andamento, eventos e passos da saga, compensações, erros de integração, latência das APIs e recursos do Kubernetes."
  layout_type = "ordered"

  # --- Requisito: volume diário de ordens de serviço ---
  #
  # Na Fase 4 o volume sai do log de avanço da saga no OS Service
  # ("Ordem {IdOrdem}: {Tipo} levou a saga para {Passo}"), contando ordens
  # distintas. Contar linhas de log daria o número de transições, não de
  # ordens: uma ordem sozinha produz cinco ou seis.
  widget {
    timeseries_definition {
      title = "Ordens de serviço distintas por passo da saga"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "cardinality"
            facet       = "@State.IdOrdem"
          }

          search_query = "service:os-service @State.Passo:*"

          group_by {
            facet = "@State.Passo"
            limit = 10

            sort_query {
              aggregation = "cardinality"
              facet       = "@State.IdOrdem"
              order       = "desc"
            }
          }
        }

        display_type = "bars"
      }
    }
  }

  # --- Os eventos da saga, por tipo ---
  #
  # É o painel que o vídeo usa para mostrar a saga acontecendo: cada evento
  # que moveu uma ordem, com o nome que ele tem no contrato.
  widget {
    timeseries_definition {
      title = "Eventos da saga por tipo"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "count"
          }

          search_query = "service:os-service @State.Tipo:*"

          group_by {
            facet = "@State.Tipo"
            limit = 15

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

  # --- Compensações: o caminho triste da saga ---
  widget {
    timeseries_definition {
      title = "Compensações por prazo (varredor do OS)"

      request {
        log_query {
          index = "*"

          compute_query {
            aggregation = "count"
          }

          search_query = "service:os-service @State.OQueFaltou:*"

          group_by {
            facet = "@State.OQueFaltou"
            limit = 5

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

  # --- Requisito: tempo médio por etapa ---
  #
  # Nenhum log da Fase 4 carrega duração: quem mede tempo aqui é o APM, e cada
  # etapa da saga é uma rota própria (diagnóstico, aprovar, assumir, finalizar).
  # Agrupar por resource_name dá o tempo por etapa a partir do trace de
  # verdade, em vez de um campo que os serviços não emitem.
  widget {
    timeseries_definition {
      title = "Tempo médio por etapa da saga (APM, por rota)"

      request {
        q            = "avg:trace.aspnet_core.request{service IN (os-service,billing-service,execucao-service,identidade-service)} by {resource_name}"
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

          search_query = "service:(os-service OR billing-service OR execucao-service OR identidade-service) status:error"

          # Por serviço, e não por nome de evento: linha de erro nem sempre
          # carrega o evento, mas sempre carrega de quem veio. Agrupar por um
          # campo ausente deixava o painel vazio justamente quando há erro.
          group_by {
            facet = "service"
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
        q            = "p50:trace.aspnet_core.request{service IN (os-service,billing-service,execucao-service,identidade-service)}"
        display_type = "line"
      }

      request {
        q            = "p95:trace.aspnet_core.request{service IN (os-service,billing-service,execucao-service,identidade-service)}"
        display_type = "line"
      }

      request {
        q            = "p99:trace.aspnet_core.request{service IN (os-service,billing-service,execucao-service,identidade-service)}"
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

  # O filtro @State.evento:FalhaProcessamentoOrdemServico era do monólito.
  # Nenhum serviço da Fase 4 emite esse campo, então o alerta nunca dispararia
  # — pior que alerta nenhum, porque parecia coberto. status:error é o que de
  # fato marca falha de processamento nos quatro serviços.
  query = "logs(\"service:(os-service OR billing-service OR execucao-service OR identidade-service) status:error\").index(\"*\").rollup(\"count\").last(\"5m\") > 3"

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

  query = "avg(last_10m):p95:trace.aspnet_core.request{service IN (os-service,billing-service,execucao-service,identidade-service)} > 1"

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

  query = "logs(\"service:(os-service OR billing-service OR execucao-service OR identidade-service) @http.status_code:[500 TO 599]\").index(\"*\").rollup(\"count\").last(\"5m\") > 10"

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
    url    = "https://${azurerm_api_management.main.name}.azure-api.net/os/health"
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
