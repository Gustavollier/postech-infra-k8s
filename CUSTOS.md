# Custos e como desligar

Estimativa para a subscription usada na Fase 3 (`eastus`). Valores de lista, arredondados.

## O que custa

| Recurso | Custo/dia | Custo/mês | Dá para desligar? |
|---|---|---|---|
| **APIM Developer** | ~US$ 1,70 | ~US$ 50 | ❌ Só deletando. Recriar leva ~40 min. |
| **AKS — 2 × Standard_B2s** | ~US$ 2,00 | ~US$ 60 | ✅ `az aks stop` (~5 min para parar/religar) |
| Azure SQL Basic (5 DTU) | ~US$ 0,16 | ~US$ 5 | ❌ Basic não tem auto-pause. Custo desprezível. |
| ACR Basic | ~US$ 0,17 | ~US$ 5 | ❌ Só armazenamento. Desprezível. |
| Log Analytics | ~US$ 0,10 | ~US$ 3 | Varia com o volume ingerido |
| Function App (Consumption) | ~US$ 0 | ~US$ 0 | Cobra por execução; ocioso é grátis |
| Datadog log forwarding (Container Apps) | ~US$ 0,10 | ~US$ 3 | Escala a zero quando ocioso |
| **Total rodando** | **~US$ 4,20/dia** | ~US$ 126 | |
| **Total com AKS parado** | **~US$ 2,20/dia** | ~US$ 66 | |

O control plane do AKS é gratuito — você paga apenas os nós. Por isso `az aks stop`
corta praticamente metade do custo diário.

## Rotina recomendada durante o desenvolvimento

```bash
# ao terminar de trabalhar
./scripts/stop-cluster.sh

# ao retomar
./scripts/start-cluster.sh
```

O `start-cluster.sh` já atualiza o kubeconfig e espera os pods ficarem Ready.
**O IP do LoadBalancer é preservado**, então o backend configurado no APIM continua
válido — não é preciso reaplicar o Terraform depois de religar.

## Níveis de desligamento

```bash
./scripts/teardown.sh 1    # pausar  — para o AKS, reversível em ~5 min
./scripts/teardown.sh 2    # compute — destrói AKS + ACR + Log Analytics, preserva APIM e banco
./scripts/teardown.sh 3    # tudo    — apaga os resource groups inteiros (definitivo)
```

O nível 2 preserva os dois recursos caros de recriar: o **APIM** (~40 min) e o
**banco com o seed**. Ambos têm `prevent_destroy = true` no Terraform justamente
para que um `terraform destroy` distraído não os leve junto.

## Depois da entrega

Rode o nível 3. O APIM Developer sozinho consome ~US$ 50/mês e continua faturando
mesmo sem tráfego — é o recurso que mais importa lembrar de apagar.

## Acompanhar o consumo

```bash
# saldo e gastos no portal
az consumption usage list --top 20 -o table

# ou pelo portal: Cost Management + Billing -> Cost analysis
```
