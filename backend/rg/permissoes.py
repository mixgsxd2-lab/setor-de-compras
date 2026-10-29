"""Matriz de permissões por perfil (fonte única para API, menu do frontend e tela de perfis).

A API verifica estas capacidades antes de cada operação; o banco repete as regras
com RLS e triggers, de modo que nenhuma camada dependa apenas da outra.
"""
from __future__ import annotations

from .errors import Proibido

TODOS = ("admin", "comprador", "solicitante", "gestor", "auditoria")

# capacidade: (grupo, descrição, perfis)
CAPACIDADES: dict[str, tuple[str, str, tuple[str, ...]]] = {
    "painel.ver": ("Visão geral", "Ver o painel de indicadores", TODOS),
    "solicitacao.ver": ("Solicitações", "Consultar solicitações (conforme o escopo do perfil)", TODOS),
    "solicitacao.criar": ("Solicitações", "Abrir solicitações de compra do setor", ("solicitante", "gestor")),
    "solicitacao.aprovar_gestor": ("Aprovações", "Aprovar, devolver ou reprovar solicitações do setor", ("gestor",)),
    "solicitacao.cancelar": ("Solicitações", "Cancelar solicitações (com justificativa)",
                             ("solicitante", "gestor", "comprador", "admin")),
    "cotacao.gerenciar": ("Cotações", "Conduzir cotações, registrar propostas e definir o fornecedor", ("comprador",)),
    "pedido.ver": ("Pedidos", "Consultar pedidos de compra",
                   ("admin", "comprador", "auditoria", "gestor", "solicitante")),
    "pedido.emitir": ("Pedidos", "Emitir, enviar e cancelar pedidos de compra", ("comprador",)),
    "recebimento.registrar": ("Recebimento", "Confirmar o recebimento das próprias solicitações", ("solicitante", "gestor")),
    "recebimento.ver": ("Recebimento", "Consultar recebimentos",
                        ("admin", "comprador", "auditoria", "gestor", "solicitante")),
    "fornecedor.ver": ("Fornecedores", "Consultar fornecedores e desempenho",
                       ("admin", "comprador", "auditoria")),
    "fornecedor.gerenciar": ("Fornecedores", "Cadastrar e editar fornecedores", ("comprador", "admin")),
    "material.ver": ("Catálogo", "Consultar materiais e categorias", TODOS),
    "material.gerenciar": ("Catálogo", "Cadastrar e editar materiais e categorias", ("comprador", "admin")),
    "alerta.ver": ("Visão geral", "Ver alertas operacionais", TODOS),
    "relatorio.ver": ("Relatórios", "Emitir relatórios e indicadores",
                      ("admin", "comprador", "auditoria", "gestor")),
    "auditoria.ver": ("Governança", "Consultar a trilha de auditoria", ("admin", "auditoria")),
    "usuario.gerenciar": ("Governança", "Gerenciar usuários, perfis e setores", ("admin",)),
    "configuracao.gerenciar": ("Governança", "Alterar alçadas e parâmetros", ("admin",)),
}


def pode(usuario: dict | None, capacidade: str) -> bool:
    return bool(usuario) and usuario["papel"] in CAPACIDADES[capacidade][2]


def exigir(usuario: dict, capacidade: str) -> None:
    if not pode(usuario, capacidade):
        raise Proibido()


def capacidades_do_papel(papel: str) -> list[str]:
    return [c for c, (_, _, papeis) in CAPACIDADES.items() if papel in papeis]


def matriz() -> list[dict]:
    return [{"capacidade": c, "grupo": g, "descricao": d, "perfis": list(p)} for c, (g, d, p) in CAPACIDADES.items()]
