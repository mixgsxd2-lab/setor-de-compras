"""Banco de dados: conexão, tabelas e dados de demonstração.

Usa SQLite (arquivo compras.db) por padrão. Se DATABASE_URL apontar para um
PostgreSQL (ex.: no Render), usa o PostgreSQL.
"""
import os
import sqlite3
from datetime import datetime, timedelta, timezone

from werkzeug.security import generate_password_hash

DATABASE_URL = os.environ.get("DATABASE_URL", "")
POSTGRES = DATABASE_URL.startswith(("postgres://", "postgresql://"))
ARQUIVO_SQLITE = os.environ.get("SQLITE_PATH", os.path.join(os.path.dirname(__file__), "compras.db"))

FUSO = timezone(timedelta(hours=-3))  # horário de Brasília


def agora():
    return datetime.now(FUSO).strftime("%Y-%m-%d %H:%M")


def conectar():
    if POSTGRES:
        import psycopg
        from psycopg.rows import dict_row
        return psycopg.connect(DATABASE_URL, row_factory=dict_row)
    con = sqlite3.connect(ARQUIVO_SQLITE)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def executar(con, sql, params=()):
    """Executa SQL escrito com '?' nos dois bancos."""
    if POSTGRES:
        sql = sql.replace("?", "%s")
    cur = con.cursor()
    cur.execute(sql, params)
    return cur


def um(con, sql, params=()):
    return executar(con, sql, params).fetchone()


def todos(con, sql, params=()):
    return executar(con, sql, params).fetchall()


def inserir(con, sql, params=()):
    """INSERT que devolve o id criado."""
    return executar(con, sql + " RETURNING id", params).fetchone()["id"]


TABELAS = """
CREATE TABLE IF NOT EXISTS usuarios (
    id          {pk},
    nome        TEXT NOT NULL,
    email       TEXT NOT NULL UNIQUE,
    senha_hash  TEXT NOT NULL,
    perfil      TEXT NOT NULL,          -- solicitante | gestor | compras | admin
    setor       TEXT NOT NULL,
    ativo       INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS fornecedores (
    id        {pk},
    nome      TEXT NOT NULL,
    cnpj      TEXT,
    telefone  TEXT,
    email     TEXT
);
CREATE TABLE IF NOT EXISTS solicitacoes (
    id                {pk},
    titulo            TEXT NOT NULL,
    setor             TEXT NOT NULL,
    urgencia          TEXT NOT NULL,      -- normal | urgente
    justificativa     TEXT NOT NULL,
    status            TEXT NOT NULL,
    solicitante_id    INTEGER NOT NULL REFERENCES usuarios (id),
    fornecedor_id     INTEGER REFERENCES fornecedores (id),
    numero_pedido     TEXT,
    valor_total       NUMERIC(12, 2),
    previsao_entrega  TEXT,
    criado_em         TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS itens (
    id              {pk},
    solicitacao_id  INTEGER NOT NULL REFERENCES solicitacoes (id),
    descricao       TEXT NOT NULL,
    quantidade      NUMERIC(12, 2) NOT NULL,
    unidade         TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS historico (
    id              {pk},
    solicitacao_id  INTEGER NOT NULL REFERENCES solicitacoes (id),
    usuario_id      INTEGER NOT NULL REFERENCES usuarios (id),
    acao            TEXT NOT NULL,
    comentario      TEXT,
    criado_em       TEXT NOT NULL
);
"""


def criar_tabelas():
    pk = "SERIAL PRIMARY KEY" if POSTGRES else "INTEGER PRIMARY KEY AUTOINCREMENT"
    with conectar() as con:
        for comando in TABELAS.format(pk=pk).split(";"):
            if comando.strip():
                executar(con, comando)


def criar_usuario(con, nome, email, senha, perfil, setor):
    return inserir(con, "INSERT INTO usuarios (nome, email, senha_hash, perfil, setor) VALUES (?, ?, ?, ?, ?)",
                   (nome, email.lower(), generate_password_hash(senha), perfil, setor))


# ---------------------------------------------------------------------------
# Primeiro acesso e demonstração
# ---------------------------------------------------------------------------
SENHA_DEMO = "teste123"
CONTAS_DEMO = [
    ("Juliana Prado", "solicitante@hospital.demo", "solicitante", "UTI Adulto"),
    ("Fernando Alves", "gestor@hospital.demo", "gestor", "UTI Adulto"),
    ("Carlos Menezes", "compras@hospital.demo", "compras", "Compras"),
    ("Renata Moura", "admin@hospital.demo", "admin", "Administração"),
]


def preparar(demo=False):
    """Cria as tabelas e, se o banco estiver vazio, o administrador ou os dados de demonstração."""
    criar_tabelas()
    with conectar() as con:
        if um(con, "SELECT COUNT(*) AS n FROM usuarios")["n"] > 0:
            return
        if demo:
            semear_demo(con)
        else:
            email = os.environ.get("ADMIN_EMAIL", "admin@hospital.local")
            senha = os.environ.get("ADMIN_SENHA", "admin123")
            criar_usuario(con, "Administrador", email, senha, "admin", "Administração")
            print(f"Administrador criado: {email} (troque a senha no primeiro acesso)")


def semear_demo(con):
    ids = {perfil: criar_usuario(con, nome, email, SENHA_DEMO, perfil, setor)
           for nome, email, perfil, setor in CONTAS_DEMO}

    fornecedores = [
        ("MedSul Distribuidora", "12.345.678/0001-90", "(51) 3222-1000", "vendas@medsul.demo"),
        ("Cirúrgica Pampa", "23.456.789/0001-01", "(51) 3333-2000", "contato@pampa.demo"),
        ("LimpaHosp Higiene", "34.567.890/0001-12", "(51) 3444-3000", "comercial@limpahosp.demo"),
    ]
    forn = [inserir(con, "INSERT INTO fornecedores (nome, cnpj, telefone, email) VALUES (?, ?, ?, ?)", f)
            for f in fornecedores]

    exemplos = [
        ("Luvas de procedimento", "urgente", "aguardando_aprovacao",
         "Estoque da UTI acaba em 3 dias por aumento de internações.",
         [("Luva nitrílica M - caixa 100", 40, "CX"), ("Luva nitrílica G - caixa 100", 20, "CX")], None),
        ("Seringas e agulhas", "normal", "aprovada",
         "Reposição mensal do estoque do setor.",
         [("Seringa 10 ml com agulha", 2000, "UN")], None),
        ("Álcool em gel", "normal", "comprada",
         "Reposição dos dispensadores dos leitos.",
         [("Álcool em gel 70% - frasco 1 L", 120, "FR")], (forn[2], "PC-0003", 1428.00)),
        ("Oxímetros de pulso", "normal", "recebida",
         "Substituição de 4 aparelhos com defeito.",
         [("Oxímetro de pulso portátil", 4, "UN")], (forn[0], "PC-0004", 3560.00)),
    ]
    acoes = {"aprovada": ["Aprovada"],
             "comprada": ["Aprovada", "Compra registrada"],
             "recebida": ["Aprovada", "Compra registrada", "Recebimento confirmado"]}
    autor = {"Aprovada": ids["gestor"], "Compra registrada": ids["compras"],
             "Recebimento confirmado": ids["solicitante"]}

    for titulo, urgencia, status, justificativa, itens, compra in exemplos:
        sid = inserir(con, """INSERT INTO solicitacoes (titulo, setor, urgencia, justificativa, status, solicitante_id, criado_em)
                              VALUES (?, 'UTI Adulto', ?, ?, ?, ?, ?)""",
                      (titulo, urgencia, justificativa, status, ids["solicitante"], agora()))
        for descricao, qtd, unidade in itens:
            executar(con, "INSERT INTO itens (solicitacao_id, descricao, quantidade, unidade) VALUES (?, ?, ?, ?)",
                     (sid, descricao, qtd, unidade))
        if compra:
            executar(con, """UPDATE solicitacoes SET fornecedor_id = ?, numero_pedido = ?, valor_total = ?,
                             previsao_entrega = ? WHERE id = ?""", (*compra, "2026-12-01", sid))
        for acao in ["Solicitação criada"] + acoes.get(status, []):
            executar(con, "INSERT INTO historico (solicitacao_id, usuario_id, acao, criado_em) VALUES (?, ?, ?, ?)",
                     (sid, autor.get(acao, ids["solicitante"]), acao, agora()))
