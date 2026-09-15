# PosTech Infra — AKS, API Management e Observabilidade

Terraform da plataforma do Tech Challenge Fase 3 (13SOAT): o cluster onde a aplicação roda, o gateway que protege as rotas, a hospedagem da Auth Function e toda a camada de monitoramento.

É o item 4 dos quatro repositórios da entrega. Os outros três entregam o código; este entrega o lugar onde eles rodam.

## O que este repositório provisiona

| Arquivo | Recursos |
|---|---|
| `main.tf` | ACR, AKS, namespace, Secret e Service `LoadBalancer` da aplicação |
| `apim.tf` | API Management (importado), named value do JWT, APIs e políticas, Log Analytics, diagnostic setting |
| `functionapp.tf` | Identidade gerenciada, storage, ambiente e Container App da Auth Function |
| `datadog.tf` | Agente no cluster (Helm), dashboard, monitors e synthetics |

## Como as peças se ligam

```
                      Internet
                          │
                          ▼
          ┌───────────────────────────────┐
          │   API Management (gateway)     │
          │   • valida o JWT               │
          │   • rate limit por IP          │
          │   • injeta X-Correlation-ID    │
          └───────┬───────────────┬────────┘
                  │               │
         rotas da API        rota /auth
                  │               │
                  ▼               ▼
        ┌──────────────┐   ┌──────────────────┐
        │ AKS          │   │ Container App    │
        │ LoadBalancer │   │ Auth Function    │
        │ → pods da API│   │ (escala a zero)  │
        └──────┬───────┘   └────────┬─────────┘
               │                    │
               └────────┬───────────┘
                        ▼
                 Azure SQL Database
                 (repo postech-infra-db)
```

O APIM é a única porta de entrada pública. O `Service` do AKS mora aqui, e não no repositório da aplicação, por dois motivos: o APIM precisa do IP dele como backend, e ele tem que existir antes dos pods subirem. O `Deployment` e o HPA ficam no repositório da aplicação.

O mesmo `validate-jwt` aceita o token de funcionário (emitido pela API) e o de cliente (emitido pela Auth Function a partir do CPF): ambos são assinados com o mesmo segredo HMAC, que vem do Key Vault e entra no APIM como named value.

## Decisões que o ambiente impôs

Três restrições desta subscription moldaram a arquitetura. Estão documentadas nos comentários do código, e resumidas aqui porque explicam escolhas que de outra forma pareceriam estranhas.

**A Auth Function roda em Container Apps, não em Function App.** A subscription tem quota **zero** para todos os planos de App Service testados — Y1, F1, B1, S1, P0v3, P1v3. Sem plano não existe Function App hospedado. Container Apps é serverless de verdade (escala a zero, cobra por requisição) e é destino oficial para Azure Functions: o container roda a imagem base oficial do Functions, com o mesmo host, os mesmos triggers e o mesmo código. Muda apenas o plano de hospedagem.

**O cluster tem 2 nós fixos, sem autoscaler.** A quota regional é de 4 vCPU, e 2 nós de 2 vCPU já são o teto. A escalabilidade exigida pelo enunciado vem do HPA sobre os pods (2 a 5 réplicas), não de nós novos. A família B (burstable) é proibida nesta subscription em `eastus`, então o SKU é `Standard_D2as_v7`.

**O ambiente de Container Apps fica em `centralus`.** A subscription permite um ambiente por região, e `eastus` estava ocupado. Efeito colateral bom: a Function fica colocalizada com o Azure SQL que ela consulta.

## Recursos importados em vez de criados

O APIM já existia quando este Terraform foi escrito, e recriar um Developer SKU leva ~40 minutos. Ele entra no state por `import`, com `prevent_destroy = true` para que um `terraform destroy` distraído não o leve junto.

Alguns outros recursos também têm blocos de `import` — a política da API principal e as operações de health foram aplicadas à mão durante a depuração, e o Container App ficou órfão de um apply que expirou. Uma vez no state, esses blocos viram no-op e podem ser removidos.

## Pipeline

`.github/workflows/terraform.yml`, autenticando no Azure por OIDC — sem senha nem certificado guardados.

| Evento | O que acontece |
|---|---|
| Pull request | `fmt`, `init`, `validate`, `plan` — o plano é comentado no PR |
| Push na `main` | `apply` |

Antes do `apply` a pipeline confirma que a imagem `postech-auth-function:latest` existe no ACR. Se não existir, ela para com uma mensagem clara em vez de falhar no meio: rode antes a pipeline do repositório da Function.

As chaves do Datadog entram como `TF_VAR_datadog_api_key` e `TF_VAR_datadog_app_key`, a partir de secrets do repositório. Nunca como arquivo versionado.

## Observabilidade

O dashboard cobre os painéis que o enunciado pede: volume diário de ordens de serviço, tempo médio por status, erros de integração, latência das APIs (p50/p95/p99) e consumo de recursos do Kubernetes, mais as réplicas em execução para mostrar o HPA em ação.

Os monitors alertam por e-mail em falha no processamento de ordens de serviço, latência p95 acima de 1s e volume anormal de 5xx. Dois testes de synthetics fazem o healthcheck do gateway e da Function a cada 5 minutos.

A correlação entre camadas funciona pelo `X-Correlation-ID`: o APIM gera ou reaproveita o header, a aplicação o promove para o escopo do logger e para a `Activity` corrente, e o agente do Datadog liga log e trace pelo mesmo ID.

## Operação

```bash
./scripts/stop-cluster.sh     # para o AKS — corta ~metade do custo diário
./scripts/start-cluster.sh    # religa e espera os pods ficarem Ready
./scripts/teardown.sh 1|2|3   # pausar | destruir compute | apagar tudo
```

O IP do LoadBalancer é preservado por `stop`/`start`, então o backend configurado no APIM continua válido — não é preciso reaplicar o Terraform depois de religar.

Custos e níveis de desligamento estão em [`CUSTOS.md`](CUSTOS.md).

## Segredos

Nada de sensível é versionado. As senhas e a chave do JWT vivem no Key Vault criado pelo `postech-infra-db` e são lidas por data source; as chaves do Datadog entram por variável de ambiente na pipeline.

O arquivo de plano do Terraform (`terraform plan -out=tfplan`) **embute o state inteiro**, com senhas em claro. Ele está no `.gitignore` — tanto como `*.tfplan` quanto como `tfplan` sem extensão — e não deve ser commitado nem publicado como artefato de pipeline.

## Repositórios da entrega

| Repo | Conteúdo |
|---|---|
| [postech-app](https://github.com/Gustavollier/postech-app) | Aplicação principal (.NET) e manifestos do AKS |
| [postech-auth-function](https://github.com/Gustavollier/postech-auth-function) | Autenticação de cliente por CPF, emite o JWT |
| [postech-infra-db](https://github.com/Gustavollier/postech-infra-db) | Azure SQL Database e Key Vault |
| **postech-infra-k8s** | este repositório |

Documentação arquitetural completa (componentes, sequência, RFCs, ADRs, ER): .[postech-app/Documents](https://github.com/Gustavollier/postech-app/tree/main/Documents).
