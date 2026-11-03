"""Testa o fluxo completo: solicitação → aprovação → compra → recebimento."""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))


@pytest.fixture()
def app(tmp_path, monkeypatch):
    monkeypatch.setenv("DEMO", "1")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    import banco
    monkeypatch.setattr(banco, "ARQUIVO_SQLITE", str(tmp_path / "teste.db"))
    banco.preparar(demo=True)
    import app as modulo
    modulo.app.config["TESTING"] = True
    return modulo.app


def entrar(cliente, perfil):
    cliente.get("/sair")
    r = cliente.post("/login", data={"email": f"{perfil}@hospital.demo", "senha": "teste123"})
    assert r.status_code == 302


def test_fluxo_completo(app):
    c = app.test_client()

    entrar(c, "solicitante")
    r = c.post("/nova", data={"titulo": "Máscaras N95", "urgencia": "urgente", "justificativa": "Surto de gripe",
                              "descricao": ["Máscara N95", ""], "quantidade": ["200", ""], "unidade": ["UN", "UN"]})
    sid = int(r.headers["Location"].rsplit("/", 1)[1])
    assert "Aguardando aprovação" in c.get(f"/solicitacao/{sid}").get_data(as_text=True)
    assert c.post(f"/solicitacao/{sid}/aprovar").status_code == 403   # solicitante não aprova

    entrar(c, "gestor")
    c.post(f"/solicitacao/{sid}/reprovar")                            # sem motivo: não reprova
    c.post(f"/solicitacao/{sid}/aprovar", data={"comentario": "ok"})
    assert "Aguardando compra" in c.get(f"/solicitacao/{sid}").get_data(as_text=True)

    entrar(c, "compras")
    c.post(f"/solicitacao/{sid}/comprar", data={"fornecedor_id": "1", "numero_pedido": "PC-99",
                                                "valor_total": "1.250,50", "previsao_entrega": "2026-12-10"})
    pagina = c.get(f"/solicitacao/{sid}").get_data(as_text=True)
    assert "Aguardando entrega" in pagina and "R$ 1.250,50" in pagina and "10/12/2026" in pagina

    entrar(c, "solicitante")
    c.post(f"/solicitacao/{sid}/receber")
    pagina = c.get(f"/solicitacao/{sid}").get_data(as_text=True)
    assert "Recebida" in pagina and "Recebimento confirmado" in pagina


def test_acesso_por_perfil(app):
    c = app.test_client()
    assert c.get("/").status_code == 302          # sem login vai para a tela de entrada
    entrar(c, "solicitante")
    assert c.get("/usuarios").status_code == 403
    assert c.get("/fornecedores").status_code == 403
    entrar(c, "admin")
    r = c.post("/usuarios", data={"nome": "Ana Lima", "email": "ana@hospital.demo", "senha": "senha-segura",
                                  "perfil": "solicitante", "setor": "Farmácia"}, follow_redirects=True)
    assert "Usuário cadastrado" in r.get_data(as_text=True)

    # Usuário de outro setor não vê as solicitações da UTI
    c.get("/sair")
    c.post("/login", data={"email": "ana@hospital.demo", "senha": "senha-segura"})
    assert c.get("/solicitacao/1").status_code == 404
