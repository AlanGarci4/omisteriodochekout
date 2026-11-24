# Prática: O mistério do checkout

> **Objetivo**: investigar um problema de verdade usando **métricas e logs juntos**. As métricas dizem **onde** e **quando** dói; os logs dizem **por quê**. Sozinha, nenhuma das duas fecha o caso.

**Tempo estimado**: 40 minutos

**Pré-requisitos**: Docker e Docker Compose; ter feito a prática whitebox desta aula (PromQL básico) e a prática da Aula 2 (LogQL básico). Se outra stack da Aula 4 ainda estiver de pé, derrube antes (`docker compose down` na pasta dela): as portas são as mesmas. Para não esperar download em sala, rode antes da aula, nesta pasta:

```bash
docker compose pull
```

---

## O chamado

> **Suporte, 14:07**: "Desde o deploy de hoje, vários clientes dizem que não conseguem finalizar a compra. Outros dizem que o site está lento. O time de desenvolvimento jura que não mudou nada no checkout."

Você é a pessoa de plantão. Descubra o que está acontecendo, corrija e prove que corrigiu.

**Regras do jogo**:

- O código da loja **não** está disponível: você só tem o que um time de plataforma normalmente tem, o `compose.yaml`, as métricas e os logs
- Investigue pelo **Grafana** (menu **Explorar**) e pelo Prometheus (<http://localhost:9090>)
- As dicas estão escondidas. Tente antes de abrir

---

## Cenário

```
                 ┌─ stdout (logs)  → Alloy → Loki ───────┐
loja ────────────┤                                       ├─→ Grafana
  ↑              └─ /metrics       ← Prometheus ─────────┘
trafego (8 clientes em paralelo)
```

- **loja**: uma loja virtual com três rotas, `/` (página inicial), `/produtos` e `/checkout` (finalizar a compra)
- **trafego**: 8 "clientes" navegando pela loja ao mesmo tempo, sem parar

Estrutura de pastas:

```
pratica-misterio-checkout/
├── compose.yaml
├── prometheus/
│   └── prometheus.yml
├── trafego/
│   └── gerar-trafego.sh
├── loki/
│   └── loki-config.yml
├── alloy/
│   └── config.alloy
└── provisioning/
    └── datasources/
        └── datasources.yml
```

---

## Como a loja funciona

O time da loja não passou o código, mas mandou este resumo.

**As rotas**

| Rota | O que faz | Tempo normal |
|---|---|---|
| `/` | página inicial | 5 a 40 ms |
| `/produtos` | lista os produtos e pede recomendações a outro serviço. Se ele não responder a tempo, mostra uma lista padrão | 20 a 120 ms |
| `/checkout` | finaliza a compra: grava o pedido no **banco de dados** | 0,5 a 1,5 s |

Em segundo plano, sem nenhum cliente esperando, a loja também roda um job que envia a newsletter e um vigia que confere o uso de memória.

**A configuração**

A loja é configurada por variáveis de ambiente, no `environment` do serviço `loja` no `compose.yaml`:

| Variável | O que é |
|---|---|
| `DB_POOL_SIZE` | quantas conexões com o banco o pool mantém abertas |
| `DB_POOL_TIMEOUT` | quantos segundos um pedido espera por uma conexão livre antes de desistir. Se não for definida, vale 2 segundos |

Hoje o `compose.yaml` define só a `DB_POOL_SIZE`. A `DB_POOL_TIMEOUT` fica nos 2 segundos.

**O pool de conexões**

- Abrir uma conexão com o banco é caro: tem rede, autenticação e memória gasta no servidor do banco. Abrir uma a cada pedido deixaria tudo lento
- Por isso a loja abre um número fixo de conexões (`DB_POOL_SIZE`) e reaproveita: esse conjunto é o **pool**
- Cada `/checkout`:
  1. pega uma conexão livre do pool
  2. grava o pedido, o que leva de 0,5 a 1,5 s
  3. devolve a conexão para o próximo pedido
- Se todas as conexões estão em uso, o pedido **espera na fila**. Se esperar mais que o `DB_POOL_TIMEOUT`, desiste, e o cliente recebe **500**
- Pense nos caixas de um banco: com 3 caixas, o 4º cliente espera na fila. Se a fila não anda, ele vai embora
- Isso é **saturação**, o "S" do USE: o recurso está tão cheio que o trabalho começa a esperar por ele

**As métricas** (em <http://localhost:8080/metrics>)

| Métrica | Tipo | O que diz |
|---|---|---|
| `http_requests_total{path, status}` | counter | quantas requisições a loja atendeu, por rota e status. É a base do Rate e do Errors do RED |
| `http_request_duration_seconds{path}` | histogram | quanto as requisições demoraram, por rota, em faixas de 10 ms a 5 s. É a base do Duration |
| `db_conexoes_em_uso` | gauge | quantas conexões do pool estão emprestadas **agora**. Sobe quando um checkout pega uma conexão e desce quando devolve |
| `process_resident_memory_bytes` | gauge | memória que o processo da loja usa de verdade |
| `process_cpu_seconds_total` | counter | tempo de CPU gasto pelo processo. Com `rate()`, quanto da CPU ele está usando |

Repare: a loja diz quantas conexões estão **em uso**, mas não quantas existem **no total**. Para saber se um valor é muito ou pouco, você vai precisar de outra fonte.

**Os logs**

- JSON no stdout, uma linha por evento, com `level`, `message`, `request_id`, `path`, `status`, `duration_ms` e campos extras conforme o evento
- Os logs do job da newsletter e do vigia de memória não têm `path`: não vêm de nenhuma requisição
- No Loki, os labels são `service="loja"` e `container="loja"`

---

## Passo 1: Subindo e reproduzindo o problema

A loja está publicada no Docker Hub como `mvalgueiroschool/pratica-misterio-app:1.0.0`. Não precisa buildar nada.

```bash
docker compose up -d
docker compose ps
# loja, trafego, prometheus, loki, alloy, grafana ... todos Up
```

Tente comprar algumas vezes:

```bash
for i in 1 2 3 4 5; do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" localhost:8080/checkout; done
```

Repare no status e no tempo de cada tentativa. O problema é real.

> Espere uns **2 minutos** antes do passo 2, para as métricas e os logs acumularem histórico.

---

## Passo 2: Métricas: o que piorou, e onde?

Comece pelo **RED** de cada rota. Responda:

1. Qual rota tem erros? Qual a **taxa de erro** dela?
2. Qual rota está **lenta**? Quanto é o p95 dela?
3. As outras rotas estão saudáveis?

<details>
<summary>Dica 1</summary>

Mesmas queries da prática whitebox, mas agrupando por `path`:

```promql
sum by (path) (rate(http_requests_total[1m]))
```

</details>

<details>
<summary>Dica 2</summary>

Taxa de erro e p95 por rota:

```promql
sum by (path) (rate(http_requests_total{status=~"5.."}[1m]))
  / sum by (path) (rate(http_requests_total[1m]))
```

```promql
histogram_quantile(0.95, sum by (le, path) (rate(http_request_duration_seconds_bucket[1m])))
```

</details>

Anote o que encontrou. Você já sabe **onde** dói, mas ainda não sabe **por quê**.

---

## Passo 3: Logs: o que a loja está dizendo?

Vá para o **Explorar**, fonte **Loki**. Antes de filtrar, veja tudo o que está chegando:

```logql
{container=~".+"}
```

- O `=~` compara com uma expressão regular, e `.+` quer dizer "qualquer texto com pelo menos um caractere". Ou seja: qualquer stream que tenha o label `container`
- O Loki não aceita um seletor que case com tudo, inclusive com vazio (`{}` ou `{container=~".*"}`). Por isso o `.+`
- Só a `loja` aparece: no `compose.yaml`, ela é o único serviço com o label `logging: "alloy"`, que o Alloy usa para escolher de quem coletar

Agora, só os erros:

```logql
{service="loja"} | json | level="ERROR"
```

Muita coisa, não? Responda:

1. Quantos **tipos** diferentes de `ERROR` aparecem?
2. Qual deles aparece **mais**?
3. Quais deles **afetam o cliente**? Use o que você descobriu no passo 2 para decidir

<details>
<summary>Dica 1</summary>

Conte os erros por mensagem:

```logql
sum by (message) (count_over_time({service="loja"} | json | level="ERROR" [1m]))
```

</details>

<details>
<summary>Dica 2</summary>

O passo 2 mostrou qual rota devolve 500. Filtre os logs por ela:

```logql
{service="loja"} | json | path="/checkout" | level="ERROR"
```

Abra uma linha e leia **todos** os campos, não só a mensagem.

</details>

> Repare: um log `ERROR` **não** quer dizer que o cliente sentiu alguma coisa. Quem diz se o cliente sentiu é a métrica.

---

## Passo 4: Juntando as pistas

O log do checkout fala do **pool de conexões** com o banco, aquele de [Como a loja funciona](#como-a-loja-funciona). Lembre: quando todas as conexões estão em uso, quem chega **espera na fila**, e quem espera mais que o `DB_POOL_TIMEOUT` recebe 500.

Responda:

1. Quantas conexões o pool tem? (Está no log, e a configuração está no `compose.yaml`)
2. Quantas estão em uso? (Está na métrica)
3. O que acontece com quem espera mais do que o limite?

<details>
<summary>Dica</summary>

```promql
db_conexoes_em_uso
```

Olhando só a métrica, o valor parece baixo. Compare com o `pool_size` do log.

</details>

Agora abra o `compose.yaml`. Alguma configuração da `loja` bate com o que você encontrou?

---

## Passo 5: Corrigindo e provando que corrigiu

Faça a correção no `compose.yaml` e recrie **só** a loja:

```bash
docker compose up -d loja
```

O `up -d` percebe que a configuração mudou e recria o container.

Corrigir não basta: **prove** que corrigiu. Espere uns 2 minutos e volte às queries dos passos 2 e 4:

- A taxa de erro do checkout foi a zero?
- O p95 do checkout caiu? Para quanto?
- O `db_conexoes_em_uso` continua colado num valor só?
- A **taxa** de requisições do checkout mudou? Por quê?
- O `ERROR` do pool sumiu do Loki? E os outros `ERROR`?

<details>
<summary>Dica</summary>

Para comparar o antes e o depois no mesmo gráfico, aumente o intervalo de tempo do Explorar para os últimos 15 ou 30 minutos.

</details>

---

## Solução

Tente resolver antes de abrir.

<details>
<summary>O que estava acontecendo</summary>

**Métricas (onde e quando)**: só o `/checkout` devolve 500, em torno de 25% das vezes, e o p95 dele fica perto de 4 s. `/` e `/produtos` estão saudáveis. A memória do processo (`process_resident_memory_bytes`) está estável.

**Logs (por quê)**: há três tipos de `ERROR`:

| Mensagem | Afeta o cliente? |
|---|---|
| `falha ao buscar recomendações` | **não**: é o mais frequente, mas o `/produtos` responde 200 com uma lista padrão. As métricas mostram a rota saudável |
| `falha ao enviar newsletter` | **não**: é um job interno, sem cliente esperando. Nem tem `path` |
| `timeout ao obter conexão do pool do banco` | **sim**: vem do `/checkout`, com `status` 500, `pool_size: 2` e `espera_s: 2.0` |

O `WARN` de memória alta também é pista falsa: a métrica de memória real não acompanha.

**Juntando**: o pool do banco tem só **2** conexões, e o `db_conexoes_em_uso` fica parado em 2, ou seja, **sempre cheio** (saturação). Com 8 clientes comprando em paralelo e cada pedido segurando uma conexão por 0,5 a 1,5 s, a fila cresce. Quem espera mais de 2 s recebe 500. Quem consegue a conexão também demora, porque esperou na fila: por isso o p95 alto.

**Causa**: `DB_POOL_SIZE=2` no `compose.yaml`.

**Correção**: `DB_POOL_SIZE=10` (qualquer valor acima do pico de concorrência, que aqui é 8). Depois dela:

- erros do checkout vão a zero e o p95 cai para perto de 1,5 s, o tempo do próprio pedido
- o `db_conexoes_em_uso` passa a variar, em vez de ficar colado no máximo
- a taxa do checkout **sobe**: os clientes não ficam mais presos na fila e compram mais vezes por minuto
- o `ERROR` do pool some; os outros dois continuam, porque nunca tiveram relação com o problema

**Por que precisou dos dois**: as métricas apontaram a rota e a saturação, mas não diziam o tamanho do pool, e um gauge parado em 2 parece baixo. Os logs tinham a causa, mas escondida entre erros mais frequentes e irrelevantes. Sem a métrica, a tendência é correr atrás do erro que mais aparece.

</details>

---

## Limpeza

```bash
docker compose down        # mantém os volumes
docker compose down -v     # apaga tudo
```

---

## Takeaways

- **Métricas** dizem **onde** e **quando**; **logs** dizem **por quê**. Investigação boa usa os dois
- O erro que **mais aparece** no log nem sempre é o que importa. Quem diz o impacto no cliente é o **RED**
- Um número sem contexto engana: "2 conexões em uso" só vira problema quando você sabe que o máximo é 2. Vale expor o limite como métrica também
- **Saturação** aparece primeiro como **latência** (fila) e só depois como **erro** (timeout)
- Corrigir não termina o incidente: **provar** com as métricas, sim
