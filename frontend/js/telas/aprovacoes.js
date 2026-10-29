// Central de aprovações: solicitações aguardando o gestor do setor, com histórico de decisões.
import { api } from "../api.js";
import { emitir, estado, rotulo } from "../estado.js";
import { atualizarConsulta, navegar } from "../roteador.js";
import { html, renderizar, on } from "../ui/dom.js";
import { icone } from "../ui/icones.js";
import {
  abas, aviso, badgeSetor, badgeSla, badgeUrgencia, cabecalho, carregandoBloco, confirmar, formato, opcoes, paginacao,
  toast, toastErro, vazio,
} from "../ui/componentes.js";

const APROVADORES = ["gestor"];
const DECISAO = { aprovado: ["sucesso", "check_circulo"], reprovado: ["perigo", "x_circulo"], devolvido: ["alerta", "devolver"] };

export async function montar({ raiz, consulta }) {
  const u = estado.usuario;
  const aprovador = APROVADORES.includes(u.papel);
  let aba = aprovador && consulta.aba !== "historico" ? "pendentes" : "historico";
  const sub = { gestor: `Solicitações do setor ${u.setor_nome} aguardando sua análise` }[u.papel] || "Histórico de todas as decisões de aprovação";
  renderizar(raiz, html`${cabecalho({ titulo: "Aprovações", sub })}
    <section class="cartao"><div id="abas"></div><div id="conteudo-aprov">${carregandoBloco(5)}</div></section>`);
  const alvo = raiz.querySelector("#conteudo-aprov");
  let filtros = { minhas: aprovador, nivel: "", decisao: "", pagina: 1 };

  async function pendentes() {
    const p = await api.get("/aprovacoes/pendentes");
    const total = p.solicitacoes.length;
    renderizar(raiz.querySelector("#abas"), abas([{ valor: "pendentes", rotulo: "Aguardando minha decisão", icone: "carimbo", qtd: total, critico: true }, { valor: "historico", rotulo: "Histórico de decisões", icone: "historico" }], aba, { nome: "aba" }));
    if (!total) { renderizar(alvo, vazio("Nenhuma aprovação pendente", "Você será notificado quando houver algo para analisar.", "", "check_circulo")); return; }
    renderizar(alvo, html`
      ${p.solicitacoes.length ? html`<div class="resumo-lista"><strong>Solicitações</strong><span>${p.solicitacoes.length} aguardando</span></div>
        <div class="tabela-envoltorio"><table class="tabela responsiva"><thead><tr><th>Solicitação</th><th>Setor</th><th>Urgência</th><th>Prazo</th><th class="num">Valor estimado</th><th class="col-acao"><span class="sr-only">Decisão</span></th></tr></thead>
        <tbody>${p.solicitacoes.map((s) => html`<tr>
          <td class="principal-td"><div class="principal-celula"><span class="codigo">${s.codigo}${s.rodada > 1 ? ` · ${s.rodada}ª rodada` : ""}</span><a href="/solicitacoes/${s.id}">${s.titulo}</a><small>${s.solicitante_nome} · ${s.itens_qtd} item(ns) · aberta ${formato.relativo(s.criado_em)}${s.aberta_por_gestor ? " · aberta pelo gestor" : ""}</small></div></td>
          <td data-rotulo="Setor">${badgeSetor(s.setor_codigo, s.setor_nome, s.setor_cor)}</td><td data-rotulo="Urgência">${badgeUrgencia(s.urgencia)}</td>
          <td data-rotulo="Prazo">${badgeSla(s.sla_situacao, s.sla_horas_restantes)}</td>
          <td data-rotulo="Valor estimado" class="num"><strong>${formato.moeda(s.valor_estimado)}</strong></td>
          <td class="col-acao"><div class="grupo-botoes"><a class="botao secundario pequeno" href="/solicitacoes/${s.id}">${icone("olho")}Analisar</a>
            <button class="botao sucesso pequeno" data-aprovar-sol="${s.id}">${icone("check")}Aprovar</button></div></td></tr>`)}</tbody></table></div>` : ""}`);
    alvo._dados = p;
  }

  async function historico() {
    renderizar(raiz.querySelector("#abas"), abas([...(aprovador ? [{ valor: "pendentes", rotulo: "Aguardando minha decisão", icone: "carimbo" }] : []), { valor: "historico", rotulo: "Histórico de decisões", icone: "historico" }], aba, { nome: "aba" }));
    const r = await api.get("/aprovacoes/historico", { ...filtros, por_pagina: 30 });
    renderizar(alvo, html`<form class="barra-filtros" id="f-hist">
        ${aprovador ? html`<label class="checkbox pequeno"><input type="checkbox" name="minhas" ${filtros.minhas ? html`checked` : ""}><span>Somente minhas decisões</span></label>` : ""}
        <select class="entrada" name="nivel" aria-label="Nível">${opcoes(estado.meta.rotulos.nivel_aprovacao, filtros.nivel, { vazio: "Todos os níveis" })}</select>
        <select class="entrada" name="decisao" aria-label="Decisão">${opcoes(estado.meta.rotulos.decisao_aprovacao, filtros.decisao, { vazio: "Todas as decisões" })}</select></form>
      ${r.itens.length ? html`<div class="tabela-envoltorio"><table class="tabela responsiva"><thead><tr><th>Decisão</th><th>Solicitação / pedido</th><th>Nível</th><th>Responsável</th><th>Parecer</th><th class="num">Valor</th></tr></thead>
        <tbody>${r.itens.map((a) => { const [tom, ic] = DECISAO[a.decisao]; return html`<tr data-href="${a.pedido_id ? `/pedidos/${a.pedido_id}` : `/solicitacoes/${a.solicitacao_id}`}">
          <td data-rotulo="Decisão"><span class="badge ${tom}">${icone(ic)}${rotulo("decisao_aprovacao", a.decisao)}</span><br><small class="texto-3 nowrap">${formato.dataHora(a.criado_em)}</small></td>
          <td class="principal-td"><div class="principal-celula"><a href="${a.pedido_id ? `/pedidos/${a.pedido_id}` : `/solicitacoes/${a.solicitacao_id}`}">${a.pedido_codigo || a.solicitacao_codigo}</a><small>${a.solicitacao_titulo} · ${a.setor_nome}</small></div></td>
          <td data-rotulo="Nível">${rotulo("nivel_aprovacao", a.nivel)}</td><td data-rotulo="Responsável">${a.usuario_nome}</td>
          <td data-rotulo="Parecer" class="pequeno texto-2">${a.parecer || "—"}</td><td data-rotulo="Valor" class="num">${formato.moeda(a.valor)}</td></tr>`; })}</tbody></table></div>${paginacao(r)}`
        : vazio("Nenhuma decisão encontrada", "", "", "historico")}`);
    raiz.querySelector("#f-hist").addEventListener("change", (e) => {
      const d = Object.fromEntries(new FormData(e.currentTarget));
      filtros = { minhas: d.minhas === "on", nivel: d.nivel, decisao: d.decisao, pagina: 1 };
      historico();
    });
  }

  const carregar = () => { atualizarConsulta({ aba: aba === "historico" && aprovador ? "historico" : "" }); return (aba === "pendentes" ? pendentes() : historico()).catch((e) => renderizar(alvo, vazio("Não foi possível carregar", e.message, "", "alerta"))); };
  on(raiz, "click", "[data-aba]", (e, b) => { aba = b.dataset.aba; carregar(); });
  on(alvo, "click", "[data-pagina]", (e, b) => { filtros.pagina = Number(b.dataset.pagina); historico(); });
  on(alvo, "click", "tr[data-href]", (e, tr) => { if (!e.target.closest("a,button")) navegar(tr.dataset.href); });
  on(alvo, "click", "[data-aprovar-sol]", async (e, b) => {
    const s = alvo._dados.solicitacoes.find((x) => x.id === b.dataset.aprovarSol);
    const det = await api.get(`/solicitacoes/${s.id}`);
    const r = await confirmar({ titulo: `Aprovar ${s.codigo}?`, rotuloConfirmar: "Assinar e aprovar", tom: "sucesso", icone: "assinatura",
      mensagem: html`<strong>${s.titulo}</strong> · ${s.setor_nome} · ${formato.moeda(s.valor_estimado)}`,
      extra: html`<ul class="lista-itens cartao">${det.itens.map((i) => html`<li><div class="item-lista"><span class="corpo-item"><strong>${i.descricao}</strong><small>${formato.numero(i.quantidade)} ${i.unidade} × ${formato.moeda(i.valor_unitario_estimado)}</small></span><span class="lado num">${formato.moeda(i.total_estimado)}</span></div></li>`)}</ul>
        ${aviso("info", "Justificativa do setor", det.solicitacao.justificativa)}`,
      justificativa: "Parecer (opcional)" });
    if (!r.confirmado) return;
    try {
      const d = await api.post(`/solicitacoes/${s.id}/acoes/aprovar`, { versao: det.solicitacao.versao, texto: r.texto });
      toast("sucesso", "Solicitação aprovada", `${s.codigo} · ${rotulo("status_solicitacao", d.solicitacao.status)}`);
      emitir("atualizar-contadores"); pendentes();
    } catch (erro) { toastErro(erro); }
  });
  await carregar();
}
