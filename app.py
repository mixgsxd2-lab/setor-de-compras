"""Compras · Hospital Rio Grande — sistema simples de solicitações de compra.

Fluxo: Solicitação → Aprovação do gestor → Compra (Compras) → Recebimento.

Perfis:
  solicitante  abre solicitações e confirma o recebimento (vê só o próprio setor)
  gestor       o mesmo que o solicitante + aprova ou reprova as solicitações do setor
  compras      registra a compra (fornecedor, nº do pedido, valor) e cadastra fornecedores (vê tudo)
  admin        tudo, inclusive cadastro de usuários
"""
import os
import secrets
from functools import wraps

from flask import Flask, abort, flash, g, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

import banco
from banco import agora, executar, inserir, todos, um

DEMO = os.environ.get("DEMO", "1") == "1"   # mostra o login rápido dos perfis de teste

PERFIS = {"solicitante": "Solicitante", "gestor": "Gestor do setor", "compras": "Compras", "admin": "Administrador"}

SETORES = ["Administração", "Centro Cirúrgico", "Compras", "Farmácia", "Internação", "Laboratório",
           "Manutenção", "Maternidade", "Nutrição", "Pronto Socorro", "TI", "UTI Adulto", "UTI Neonatal"]

STATUS = {
    "aguardando_aprovacao": "Aguardando aprovação",
    "aprovada": "Aguardando compra",
    "comprada": "Aguardando entrega",
    "recebida": "Recebida",
    "reprovada": "Reprovada",
    "cancelada": "Cancelada",
}

UNIDADES = ["UN", "CX", "PCT", "FR", "KG", "L", "M", "PAR", "SERV"]

app = Flask(__name__)
app.config.update(
    SECRET_KEY=os.environ.get("SECRET_KEY") or secrets.token_hex(32),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)
banco.preparar(demo=DEMO)


# ---------------------------------------------------------------------------
# Infraestrutura: conexão por requisição, usuário logado e formatação
# ---------------------------------------------------------------------------
def db():
    if "db" not in g:
        g.db = banco.conectar()
    return g.db


@app.teardown_appcontext
def fechar_db(erro):
    con = g.pop("db", None)
    if con is not None:
        if erro is None:
            con.commit()
        con.close()


@app.before_request
def carregar_usuario():
    g.usuario = None
    if "usuario_id" in session:
        g.usuario = um(db(), "SELECT * FROM usuarios WHERE id = ? AND ativo = 1", (session["usuario_id"],))


def login_obrigatorio(*perfis):
    """Exige login; se perfis forem informados, exige um deles."""
    def decorador(view):
        @wraps(view)
        def envolvida(*args, **kwargs):
            if g.usuario is None:
                return redirect(url_for("login"))
            if perfis and g.usuario["perfil"] not in perfis:
                abort(403)
            return view(*args, **kwargs)
        return envolvida
    return decorador


@app.context_processor
def variaveis_globais():
    return {"usuario": g.get("usuario"), "PERFIS": PERFIS, "STATUS": STATUS}


@app.template_filter("moeda")
def moeda(valor):
    if valor is None:
        return "—"
    return "R$ " + f"{float(valor):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


@app.template_filter("data")
def data_br(texto):
    if not texto:
        return "—"
    data, _, hora = str(texto).partition(" ")
    a, m, d = data.split("-")
    return f"{d}/{m}/{a} {hora}".strip()


@app.template_filter("numero")
def numero(valor):
    v = float(valor)
    return str(int(v)) if v.is_integer() else f"{v:.2f}".replace(".", ",")


def para_numero(texto):
    """Converte '1.234,56' ou '1234.56' em float."""
    texto = (texto or "").replace("R$", "").strip()
    if "," in texto:
        texto = texto.replace(".", "").replace(",", ".")
    try:
        return float(texto)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Regras de acesso das solicitações
# ---------------------------------------------------------------------------
def ve_tudo(u):
    return u["perfil"] in ("compras", "admin")


def buscar_solicitacao(sid):
    s = um(db(), """SELECT s.*, u.nome AS solicitante, f.nome AS fornecedor
                    FROM solicitacoes s
                    JOIN usuarios u ON u.id = s.solicitante_id
                    LEFT JOIN fornecedores f ON f.id = s.fornecedor_id
                    WHERE s.id = ?""", (sid,))
    if s is None or (not ve_tudo(g.usuario) and s["setor"] != g.usuario["setor"]):
        abort(404)
    return s


def acoes_permitidas(s, u):
    """Lista o que o usuário pode fazer com a solicitação agora."""
    acoes = []
    if s["status"] == "aguardando_aprovacao":
        gestor_do_setor = u["perfil"] == "gestor" and u["setor"] == s["setor"] and u["id"] != s["solicitante_id"]
        if gestor_do_setor or u["perfil"] == "admin":
            acoes.append("aprovar")
        if u["id"] == s["solicitante_id"] or u["perfil"] == "admin":
            acoes.append("cancelar")
    if s["status"] == "aprovada" and u["perfil"] in ("compras", "admin"):
        acoes.append("comprar")
    if s["status"] == "comprada" and (u["setor"] == s["setor"] or ve_tudo(u)):
        acoes.append("receber")
    return acoes


def registrar(sid, acao, comentario=None):
    executar(db(), "INSERT INTO historico (solicitacao_id, usuario_id, acao, comentario, criado_em) VALUES (?, ?, ?, ?, ?)",
             (sid, g.usuario["id"], acao, comentario or None, agora()))


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        u = um(db(), "SELECT * FROM usuarios WHERE email = ? AND ativo = 1", (email,))
        if u and check_password_hash(u["senha_hash"], request.form.get("senha", "")):
            session.clear()
            session["usuario_id"] = u["id"]
            return redirect(url_for("painel"))
        flash("E-mail ou senha incorretos.", "erro")
    contas_demo = [{"email": e, "nome": n, "perfil": p, "senha": banco.SENHA_DEMO}
                   for n, e, p, _ in banco.CONTAS_DEMO] if DEMO else []
    return render_template("login.html", contas_demo=contas_demo)


@app.route("/sair")
def sair():
    session.clear()
    return redirect(url_for("login"))


@app.route("/senha", methods=["GET", "POST"])
@login_obrigatorio()
def trocar_senha():
    if request.method == "POST":
        atual, nova = request.form.get("atual", ""), request.form.get("nova", "")
        if not check_password_hash(g.usuario["senha_hash"], atual):
            flash("Senha atual incorreta.", "erro")
        elif len(nova) < 8:
            flash("A nova senha precisa ter pelo menos 8 caracteres.", "erro")
        else:
            executar(db(), "UPDATE usuarios SET senha_hash = ? WHERE id = ?", (generate_password_hash(nova), g.usuario["id"]))
            flash("Senha alterada.", "ok")
            return redirect(url_for("painel"))
    return render_template("senha.html")


# ---------------------------------------------------------------------------
# Solicitações
# ---------------------------------------------------------------------------
@app.route("/")
@login_obrigatorio()
def painel():
    u = g.usuario
    filtro_setor = "" if ve_tudo(u) else " AND s.setor = ?"
    params = () if ve_tudo(u) else (u["setor"],)
    lista = todos(db(), f"""SELECT s.*, u.nome AS solicitante FROM solicitacoes s
                            JOIN usuarios u ON u.id = s.solicitante_id
                            WHERE 1 = 1{filtro_setor}
                            ORDER BY s.id DESC""", params)

    # "Aguardando você": o que este usuário precisa aprovar, comprar ou receber
    pendentes = [s for s in lista if set(acoes_permitidas(s, u)) - {"cancelar"}]
    status = request.args.get("status", "")
    if status in STATUS:
        lista = [s for s in lista if s["status"] == status]
    return render_template("painel.html", lista=lista, pendentes=pendentes, status=status)


@app.route("/nova", methods=["GET", "POST"])
@login_obrigatorio("solicitante", "gestor", "admin")
def nova():
    if request.method == "POST":
        f = request.form
        itens = []
        for descricao, qtd, unidade in zip(f.getlist("descricao"), f.getlist("quantidade"), f.getlist("unidade")):
            if descricao.strip():
                quantidade = para_numero(qtd)
                if not quantidade or quantidade <= 0:
                    flash(f"Informe a quantidade do item “{descricao.strip()}”.", "erro")
                    return render_template("nova.html", unidades=UNIDADES, form=f)
                itens.append((descricao.strip(), quantidade, unidade if unidade in UNIDADES else "UN"))

        titulo, justificativa = f.get("titulo", "").strip(), f.get("justificativa", "").strip()
        if not titulo or not justificativa or not itens:
            flash("Preencha o título, a justificativa e pelo menos um item.", "erro")
            return render_template("nova.html", unidades=UNIDADES, form=f)

        sid = inserir(db(), """INSERT INTO solicitacoes (titulo, setor, urgencia, justificativa, status, solicitante_id, criado_em)
                               VALUES (?, ?, ?, ?, 'aguardando_aprovacao', ?, ?)""",
                      (titulo, g.usuario["setor"], "urgente" if f.get("urgencia") == "urgente" else "normal",
                       justificativa, g.usuario["id"], agora()))
        for item in itens:
            executar(db(), "INSERT INTO itens (solicitacao_id, descricao, quantidade, unidade) VALUES (?, ?, ?, ?)",
                     (sid, *item))
        registrar(sid, "Solicitação criada")
        flash("Solicitação enviada para aprovação.", "ok")
        return redirect(url_for("detalhe", sid=sid))
    return render_template("nova.html", unidades=UNIDADES, form={})


@app.route("/solicitacao/<int:sid>")
@login_obrigatorio()
def detalhe(sid):
    s = buscar_solicitacao(sid)
    itens = todos(db(), "SELECT * FROM itens WHERE solicitacao_id = ? ORDER BY id", (sid,))
    historico = todos(db(), """SELECT h.*, u.nome FROM historico h JOIN usuarios u ON u.id = h.usuario_id
                              WHERE h.solicitacao_id = ? ORDER BY h.id""", (sid,))
    fornecedores = todos(db(), "SELECT id, nome FROM fornecedores ORDER BY nome")
    return render_template("detalhe.html", s=s, itens=itens, historico=historico,
                           fornecedores=fornecedores, acoes=acoes_permitidas(s, g.usuario))


@app.route("/solicitacao/<int:sid>/<acao>", methods=["POST"])
@login_obrigatorio()
def agir(sid, acao):
    s = buscar_solicitacao(sid)
    permitidas = acoes_permitidas(s, g.usuario)
    f = request.form
    comentario = f.get("comentario", "").strip()

    if acao in ("aprovar", "reprovar") and "aprovar" in permitidas:
        if acao == "reprovar" and not comentario:
            flash("Informe o motivo da reprovação.", "erro")
            return redirect(url_for("detalhe", sid=sid))
        novo = "aprovada" if acao == "aprovar" else "reprovada"
        executar(db(), "UPDATE solicitacoes SET status = ? WHERE id = ?", (novo, sid))
        registrar(sid, "Aprovada" if novo == "aprovada" else "Reprovada", comentario)

    elif acao == "cancelar" and acao in permitidas:
        executar(db(), "UPDATE solicitacoes SET status = 'cancelada' WHERE id = ?", (sid,))
        registrar(sid, "Cancelada", comentario)

    elif acao == "comprar" and acao in permitidas:
        valor = para_numero(f.get("valor_total"))
        if not f.get("fornecedor_id", "").isdigit() or valor is None:
            flash("Informe o fornecedor e o valor total.", "erro")
            return redirect(url_for("detalhe", sid=sid))
        executar(db(), """UPDATE solicitacoes SET status = 'comprada', fornecedor_id = ?, numero_pedido = ?,
                          valor_total = ?, previsao_entrega = ? WHERE id = ?""",
                 (int(f["fornecedor_id"]), f.get("numero_pedido", "").strip() or None, valor,
                  f.get("previsao_entrega") or None, sid))
        registrar(sid, "Compra registrada", comentario)

    elif acao == "receber" and acao in permitidas:
        executar(db(), "UPDATE solicitacoes SET status = 'recebida' WHERE id = ?", (sid,))
        registrar(sid, "Recebimento confirmado", comentario)

    else:
        abort(403)
    flash("Solicitação atualizada.", "ok")
    return redirect(url_for("detalhe", sid=sid))


# ---------------------------------------------------------------------------
# Fornecedores
# ---------------------------------------------------------------------------
@app.route("/fornecedores", methods=["GET", "POST"])
@login_obrigatorio("compras", "admin")
def fornecedores():
    if request.method == "POST":
        f = request.form
        if not f.get("nome", "").strip():
            flash("Informe o nome do fornecedor.", "erro")
        else:
            executar(db(), "INSERT INTO fornecedores (nome, cnpj, telefone, email) VALUES (?, ?, ?, ?)",
                     (f["nome"].strip(), f.get("cnpj", "").strip(), f.get("telefone", "").strip(), f.get("email", "").strip()))
            flash("Fornecedor cadastrado.", "ok")
        return redirect(url_for("fornecedores"))
    return render_template("fornecedores.html", lista=todos(db(), "SELECT * FROM fornecedores ORDER BY nome"))


# ---------------------------------------------------------------------------
# Usuários (somente administrador)
# ---------------------------------------------------------------------------
@app.route("/usuarios", methods=["GET", "POST"])
@login_obrigatorio("admin")
def usuarios():
    if request.method == "POST":
        f = request.form
        email = f.get("email", "").strip().lower()
        if not f.get("nome", "").strip() or "@" not in email or len(f.get("senha", "")) < 8:
            flash("Preencha nome, e-mail e uma senha com pelo menos 8 caracteres.", "erro")
        elif f.get("perfil") not in PERFIS or f.get("setor") not in SETORES:
            flash("Perfil ou setor inválido.", "erro")
        elif um(db(), "SELECT id FROM usuarios WHERE email = ?", (email,)):
            flash("Já existe um usuário com esse e-mail.", "erro")
        else:
            banco.criar_usuario(db(), f["nome"].strip(), email, f["senha"], f["perfil"], f["setor"])
            flash("Usuário cadastrado.", "ok")
        return redirect(url_for("usuarios"))
    lista = todos(db(), "SELECT * FROM usuarios ORDER BY ativo DESC, nome")
    return render_template("usuarios.html", lista=lista, setores=SETORES)


@app.route("/usuarios/<int:uid>/ativo", methods=["POST"])
@login_obrigatorio("admin")
def alternar_usuario(uid):
    if uid == g.usuario["id"]:
        flash("Você não pode desativar a si mesmo.", "erro")
    else:
        executar(db(), "UPDATE usuarios SET ativo = 1 - ativo WHERE id = ?", (uid,))
    return redirect(url_for("usuarios"))


@app.route("/usuarios/<int:uid>/senha", methods=["POST"])
@login_obrigatorio("admin")
def redefinir_senha(uid):
    nova = request.form.get("senha", "")
    if len(nova) < 8:
        flash("A senha precisa ter pelo menos 8 caracteres.", "erro")
    else:
        executar(db(), "UPDATE usuarios SET senha_hash = ? WHERE id = ?", (generate_password_hash(nova), uid))
        flash("Senha redefinida.", "ok")
    return redirect(url_for("usuarios"))


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 8000)), debug=True)
