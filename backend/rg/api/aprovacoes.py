"""Central de aprovações: pendências do usuário (solicitações e pedidos) e histórico de decisões."""
from __future__ import annotations

from flask import Blueprint, current_app, g, jsonify, request

from ..rotulos import DECISAO_APROVACAO, NIVEL_APROVACAO
from ..seguranca.sessao import requer_login, tx
from ..validacao import Campo, validar
from ._util import paginacao

bp = Blueprint("aprovacoes", __name__)


def pendencias(cur, usuario: dict) -> dict:
    papel = usuario["papel"]
    solicitacoes, pedidos = [], []
    colunas = """v.id, v.codigo, v.titulo, v.tipo, v.status, v.urgencia, v.setor_codigo, v.setor_nome, v.setor_cor,
                 v.solicitante_nome, v.valor_estimado, v.criado_em, v.atualizado_em, v.sla_situacao, v.sla_horas_restantes,
                 v.itens_qtd, v.rodada, v.aberta_por_gestor"""
    if papel == "gestor":
        cur.execute(f"""select {colunas} from rg.v_solicitacoes v
                         where v.status = 'aguardando_gestor' and v.setor_codigo = %s
                         order by array_position(array['imediato','urgente','normal'], v.urgencia::text), v.criado_em""",
                    (usuario["setor_codigo"],))
        solicitacoes = cur.fetchall()
    return {"solicitacoes": solicitacoes, "pedidos": pedidos}


@bp.get("/aprovacoes/pendentes")
@requer_login
def pendentes():
    with tx() as cur:
        dados = pendencias(cur, g.usuario)
    return jsonify(dados)


@bp.get("/aprovacoes/historico")
@requer_login
def historico():
    args = validar(request.args.to_dict(), [
        Campo("minhas", "bool"),
        Campo("nivel", "escolha", escolhas=tuple(NIVEL_APROVACAO)),
        Campo("decisao", "escolha", escolhas=tuple(DECISAO_APROVACAO)),
        Campo("inicio", "data"),
        Campo("fim", "data"),
    ])
    pagina, por_pagina = paginacao(30)
    where, params = ["true"], []
    if args.get("minhas"):
        where.append("a.usuario_id = %s")
        params.append(g.usuario["id"])
    for campo in ("nivel", "decisao"):
        if args.get(campo):
            where.append(f"a.{campo} = %s")
            params.append(args[campo])
    tz = current_app.config["TIMEZONE"]
    if args.get("inicio"):
        where.append("(a.criado_em at time zone %s)::date >= %s")
        params += [tz, args["inicio"]]
    if args.get("fim"):
        where.append("(a.criado_em at time zone %s)::date <= %s")
        params += [tz, args["fim"]]
    clausula = " and ".join(where)
    with tx() as cur:
        cur.execute(f"select count(*) as n from rg.aprovacoes a where {clausula}", params)
        total = cur.fetchone()["n"]
        cur.execute(f"""select a.*, u.nome as usuario_nome, s.codigo as solicitacao_codigo, s.titulo as solicitacao_titulo,
                               st.nome as setor_nome, st.cor as setor_cor, p.codigo as pedido_codigo
                          from rg.aprovacoes a
                          join rg.solicitacoes s on s.id = a.solicitacao_id
                          join rg.setores st on st.codigo = s.setor_codigo
                          left join rg.pedidos p on p.id = a.pedido_id
                          left join rg.v_usuarios_publico u on u.id = a.usuario_id
                         where {clausula} order by a.criado_em desc limit %s offset %s""",
                    (*params, por_pagina, (pagina - 1) * por_pagina))
        itens = cur.fetchall()
    return jsonify({"itens": itens, "total": total, "pagina": pagina, "por_pagina": por_pagina})
