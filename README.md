<h1 align="center">Rinha de Backend 2026 — Zig + C/AVX2</h1>

<p align="center"><strong>API de detecção de fraude usando busca vetorial IVF com kernels AVX2 via FFI C</strong></p>

<p align="center">
  <img src="https://img.shields.io/github/license/macedot/rinha-2026-zig?color=blue" alt="License" />
  <img src="https://img.shields.io/badge/Zig-0.16-F7A41D?logo=zig&logoColor=white" alt="Zig" />
  <img src="https://img.shields.io/badge/C-AVX2-00599C?logo=c&logoColor=white" alt="C/AVX2" />
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker" />
</p>

---

**Submissão para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026).** Servidor HTTP em Zig, vetorizador e parser JSON nativos, ponte de busca vetorial IVF/AVX2 via FFI C e submódulo [`rinha-2026-base`](https://github.com/macedot/rinha-2026-base).

> A ponte IVF C/AVX2 é compartilhada entre as implementações via submódulo git. Veja [`rinha-2026-base`](https://github.com/macedot/rinha-2026-base) para detalhes do algoritmo de busca.

## Início Rápido

```bash
docker compose up --build
```

A API escuta na porta `9999`.

## API

### `GET /ready`
Retorna `200 OK` quando a API está pronta.

### `POST /fraud-score`

```json
{"approved": true, "fraud_score": 0.0000}
```

## Arquitetura

```
Cliente → passa (round-robin UDS) → api1 / api2
                                       ├── HTTP server (Zig)
                                       ├── Vetorizador 14-dim (Zig)
                                       └── Ponte IVF C/AVX2 (FFI + submódulo)
```

### Componentes

| Componente | Linguagem | Função |
|-----------|----------|------|
| **passa** | Rust | Balanceador round-robin sobre UDS |
| **Servidor HTTP** | Zig | Manipulação HTTP, listener UDS |
| **Vetorizador** | Zig | 14 dimensões seguindo normalização oficial |
| **Parser JSON** | Zig | Parser customizado sem alocação |
| **Ponte IVF** | C/AVX2 (FFI) | Submódulo [`rinha-2026-base`](https://github.com/macedot/rinha-2026-base) |

## Configuração

| Variável | Padrão | Descrição |
|----------|---------|-----------|
| `IVF_NPROBE` | `8` | Clusters sondados na passada rápida |
| `IVF_FULL_NPROBE` | `24` | Clusters sondados na passada completa |

## Estrutura

```
├── zig/
│   ├── src/
│   │   ├── main.zig         # Servidor HTTP
│   │   ├── vectorizer.zig   # Vetorizador 14-dim
│   │   └── json_parser.zig  # Parser JSON
│   └── build.zig            # Build system (inclui bridge submodule)
├── bridge/                  # Submódulo: macedot/rinha-2026-base
├── resources/
├── data/
│   └── index.bin            # Índice IVF1 (3M vetores, 4096 clusters)
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## CI/CD

GitHub Actions publica imagem `ghcr.io/macedot/rinha-2026-zig` a cada release.

## Ambiente de Teste

Mac Mini Late 2014 (2.6 GHz Haswell, 8 GB RAM). Limites Docker: **1.0 CPU**, **350 MB** memória.

## Licença

MIT
