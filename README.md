# Compras · Hospital Rio Grande

Sistema simples para o setor de compras do hospital.

**Solicitação → Aprovação do gestor → Compra → Recebimento**

## Perfis

| Perfil | O que faz |
|---|---|
| Solicitante | Abre solicitações e confirma o recebimento. Vê só as do seu setor. |
| Gestor do setor | O mesmo que o solicitante, e aprova ou reprova as solicitações do setor (exceto as próprias). |
| Compras | Registra a compra (fornecedor, nº do pedido, valor, previsão de entrega) e cadastra fornecedores. Vê tudo. |
| Administrador | Faz tudo e cadastra usuários. |

## Como rodar

**Windows:** dois cliques em `INICIAR.bat` (precisa do Python 3.12+).

**Terminal:**

```bash
pip install -r requirements.txt
python app.py
```

Abra http://127.0.0.1:8000. Na tela de entrada há botões para testar cada perfil (senha `teste123`).

## Uso real

Para usar sem os dados de teste, defina `DEMO=0` antes do primeiro início. Em um banco vazio, o sistema cria um administrador com `ADMIN_EMAIL` / `ADMIN_SENHA` (padrão: `admin@hospital.local` / `admin123`, troque em **Senha** no primeiro acesso).

| Variável | Para quê |
|---|---|
| `DEMO` | `1` mostra os perfis de teste (padrão), `0` desliga |
| `SECRET_KEY` | Chave das sessões. Defina em produção |
| `DATABASE_URL` | PostgreSQL. Sem ela, os dados ficam no arquivo `compras.db` |
| `ADMIN_EMAIL`, `ADMIN_SENHA` | Primeiro administrador (só em banco vazio) |

**Render:** o `render.yaml` cria o site e um PostgreSQL. O PostgreSQL do plano gratuito expira em 30 dias.

## Arquivos

```
app.py         telas e regras do fluxo
banco.py       banco de dados e dados de teste
templates/     páginas HTML
static/        estilo e logotipo
tests/         teste do fluxo completo (python -m pytest)
```

Setores, unidades e status ficam no topo de `app.py` e podem ser editados ali.
