-- =====================================================================
-- 0005 — Fluxo simplificado: sem aprovação da Diretoria nem do Financeiro
-- =====================================================================
-- * A solicitação é aprovada somente pelo gestor do setor (inclusive as abertas por ele mesmo).
-- * O pedido de compra nasce aprovado: o comprador pode enviá-lo ao fornecedor logo após a emissão.
-- * Financeiro, Diretoria e Auditoria viram um único perfil somente leitura ("Visão geral", valor 'auditoria').
-- Os valores antigos dos enumerados permanecem (o PostgreSQL não os remove), mas deixam de ser usados.

create or replace function rg.tg_solicitacao_inserir() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_setor rg.setores;
  v_papel rg.papel_usuario := rg.papel_atual();
begin
  if v_papel is null or v_papel not in ('solicitante', 'gestor') then
    raise exception 'Somente solicitantes e gestores de setor abrem solicitações de compra' using errcode = '42501';
  end if;
  select * into v_setor from rg.setores where codigo = new.setor_codigo;
  if not v_setor.operacional or not v_setor.ativo then
    raise exception 'O setor % não pode abrir solicitações de compra', new.setor_codigo using errcode = 'P0001';
  end if;
  new.aberta_por_gestor := v_papel = 'gestor';
  new.status := 'aguardando_gestor';
  new.criado_em := now();
  new.atualizado_em := now();
  new.codigo := 'SC-' || to_char(new.criado_em at time zone 'America/Sao_Paulo', 'YYYY') || '-'
                || lpad(nextval('rg.solicitacao_codigo_seq')::text, 5, '0');
  new.sla_prazo_limite := new.criado_em + rg.sla_intervalo(new.urgencia);
  new.rodada := 1;
  new.versao := 1;
  new.valor_final := null;
  new.comprador_id := null;
  new.cotacao_vencedora_id := null;
  new.justificativa_escolha := null;
  new.motivo_devolucao := null;
  new.motivo_reprovacao := null;
  new.motivo_cancelamento := null;
  new.aprovado_gestor_por := null;
  new.aprovado_gestor_em := null;
  new.aprovado_diretoria_por := null;
  new.aprovado_diretoria_em := null;
  new.aprovado_em := null;
  new.sla_concluido_em := null;
  new.cotacao_iniciada_em := null;
  new.fornecedor_definido_em := null;
  new.pedido_emitido_em := null;
  new.finalizado_em := null;
  return new;
end $$;;

create or replace function rg.tg_solicitacao_validar() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_papel    rg.papel_usuario := rg.papel_atual();
  v_uid      uuid := rg.usuario_atual_id();
  v_setor    text := rg.setor_atual();
  v_do_setor boolean;
  v_ops      text[] := array['sla_alerta_notificado_em', 'sla_estouro_notificado_em', 'atualizado_em'];
  v_conteudo text[] := array['titulo', 'descricao', 'justificativa', 'tipo', 'urgencia', 'local_entrega', 'data_necessidade'];
  v_cot      rg.cotacoes;
  v_n        int;
  v_itens    int;
  v_menor    numeric;
  v_pedido   rg.status_pedido;
begin
  -- Alterações exclusivamente operacionais (marcadores de alerta de SLA)
  if (to_jsonb(new) - v_ops) = (to_jsonb(old) - v_ops) then
    return new;
  end if;

  if new.id <> old.id or new.codigo <> old.codigo or new.solicitante_id <> old.solicitante_id
     or new.setor_codigo <> old.setor_codigo or new.criado_em <> old.criado_em
     or new.aberta_por_gestor <> old.aberta_por_gestor then
    raise exception 'Campos estruturais da solicitação não podem ser alterados' using errcode = 'P0001';
  end if;
  if rg.status_terminal(old.status) then
    raise exception 'A solicitação % já foi encerrada', old.codigo using errcode = 'P0001';
  end if;
  if v_papel is null then
    raise exception 'Usuário sem permissão para alterar solicitações' using errcode = '42501';
  end if;
  if v_papel = 'auditoria' then
    raise exception 'O perfil Auditoria possui acesso somente leitura' using errcode = '42501';
  end if;
  v_do_setor := v_papel in ('solicitante', 'gestor') and v_setor = old.setor_codigo;

  -- Conteúdo: somente o setor, quando a solicitação foi devolvida para ajustes
  if exists (select 1 from unnest(v_conteudo) k where to_jsonb(new) -> k is distinct from to_jsonb(old) -> k)
     and not (v_do_setor and old.status = 'devolvida') then
    raise exception 'A solicitação só pode ser editada pelo setor quando devolvida para ajustes' using errcode = 'P0001';
  end if;

  if new.urgencia is distinct from old.urgencia then
    new.sla_prazo_limite := old.criado_em + rg.sla_intervalo(new.urgencia);
    new.sla_alerta_notificado_em := null;
    new.sla_estouro_notificado_em := null;
  else
    new.sla_prazo_limite := old.sla_prazo_limite;
  end if;

  -- Campos de controle são definidos exclusivamente pela máquina de estados
  new.rodada := old.rodada;
  new.aprovado_gestor_por := old.aprovado_gestor_por;
  new.aprovado_gestor_em := old.aprovado_gestor_em;
  new.aprovado_diretoria_por := old.aprovado_diretoria_por;
  new.aprovado_diretoria_em := old.aprovado_diretoria_em;
  new.aprovado_em := old.aprovado_em;
  new.cotacao_iniciada_em := old.cotacao_iniciada_em;
  new.fornecedor_definido_em := old.fornecedor_definido_em;
  new.pedido_emitido_em := old.pedido_emitido_em;
  new.finalizado_em := old.finalizado_em;
  new.sla_concluido_em := old.sla_concluido_em;
  new.valor_final := old.valor_final;
  if new.status is not distinct from old.status then
    new.comprador_id := old.comprador_id;
    new.cotacao_vencedora_id := old.cotacao_vencedora_id;
    new.justificativa_escolha := old.justificativa_escolha;
    new.motivo_devolucao := old.motivo_devolucao;
    new.motivo_reprovacao := old.motivo_reprovacao;
    new.motivo_cancelamento := old.motivo_cancelamento;
  end if;

  if new.status is distinct from old.status then
    if new.status <> 'devolvida' then new.motivo_devolucao := old.motivo_devolucao; end if;
    if new.status <> 'reprovada' then new.motivo_reprovacao := old.motivo_reprovacao; end if;
    if new.status <> 'cancelada' then new.motivo_cancelamento := old.motivo_cancelamento; end if;
    if new.status <> 'aguardando_pedido' then
      new.cotacao_vencedora_id := old.cotacao_vencedora_id;
      new.justificativa_escolha := old.justificativa_escolha;
    end if;
    if new.status <> 'em_cotacao' then new.comprador_id := old.comprador_id; end if;

    case
      -- 1. Aprovação do gestor do setor
      when old.status = 'aguardando_gestor' and new.status in ('aprovada', 'aguardando_diretoria', 'reprovada', 'devolvida') then
        if not (v_papel = 'gestor' and v_setor = old.setor_codigo) then
          raise exception 'Somente o gestor do setor aprova esta solicitação' using errcode = '42501';
        end if;
        if new.status in ('aprovada', 'aguardando_diretoria') then
          new.aprovado_gestor_por := v_uid;
          new.aprovado_gestor_em := now();
          new.status := 'aprovada';
        end if;

      -- 1b. Aprovação da Diretoria
      when old.status = 'aguardando_diretoria' and new.status in ('aprovada', 'reprovada', 'devolvida') then
        if v_papel <> 'diretoria' then
          raise exception 'Somente a Diretoria aprova solicitações acima da alçada' using errcode = '42501';
        end if;
        if new.status = 'aprovada' then
          new.aprovado_diretoria_por := v_uid;
          new.aprovado_diretoria_em := now();
        end if;

      -- Reenvio após ajustes
      when old.status = 'devolvida' and new.status in ('aguardando_gestor', 'aguardando_diretoria') then
        if not v_do_setor then
          raise exception 'Somente o setor solicitante pode reenviar a solicitação' using errcode = '42501';
        end if;
        new.status := 'aguardando_gestor';
        new.rodada := old.rodada + 1;
        new.aprovado_gestor_por := null;
        new.aprovado_gestor_em := null;
        new.aprovado_diretoria_por := null;
        new.aprovado_diretoria_em := null;

      -- Cancelamento antes da aprovação
      when old.status in ('aguardando_gestor', 'aguardando_diretoria', 'devolvida') and new.status = 'cancelada' then
        if not (v_do_setor or v_papel = 'admin') then
          raise exception 'Somente o setor solicitante ou a administração pode cancelar' using errcode = '42501';
        end if;

      -- 2 → 3. Comprador assume a cotação
      when old.status = 'aprovada' and new.status = 'em_cotacao' then
        if v_papel <> 'comprador' then
          raise exception 'Somente o comprador inicia a cotação' using errcode = '42501';
        end if;
        new.comprador_id := v_uid;
        new.cotacao_iniciada_em := now();

      -- Cancelamento pelo setor de Compras
      when old.status in ('aprovada', 'em_cotacao', 'aguardando_pedido') and new.status = 'cancelada' then
        if v_papel not in ('comprador', 'admin') then
          raise exception 'Após a aprovação, somente Compras ou a administração pode cancelar' using errcode = '42501';
        end if;

      -- 3 → 4. Definição do fornecedor (proposta vencedora)
      when old.status = 'em_cotacao' and new.status = 'aguardando_pedido' then
        if v_papel <> 'comprador' then
          raise exception 'Somente o comprador define o fornecedor' using errcode = '42501';
        end if;
        select * into v_cot from rg.cotacoes where id = new.cotacao_vencedora_id;
        if v_cot.id is null or v_cot.solicitacao_id <> old.id or not v_cot.selecionada then
          raise exception 'Selecione a proposta vencedora' using errcode = 'P0001';
        end if;
        select count(*) into v_itens from rg.solicitacao_itens where solicitacao_id = old.id;
        if (select count(*) from rg.cotacao_itens where cotacao_id = v_cot.id) < v_itens then
          raise exception 'A proposta vencedora precisa cotar todos os itens da solicitação' using errcode = 'P0001';
        end if;
        select count(*) into v_n from rg.cotacoes where solicitacao_id = old.id;
        select min(c.valor_total) into v_menor from rg.cotacoes c
         where c.solicitacao_id = old.id
           and (select count(*) from rg.cotacao_itens ci where ci.cotacao_id = c.id) >= v_itens;
        if (v_n < coalesce(rg.config_num('minimo_cotacoes'), 1) or v_cot.valor_total > v_menor)
           and char_length(btrim(coalesce(new.justificativa_escolha, ''))) < 10 then
          raise exception 'Justifique a escolha (mínimo 10 caracteres): menos propostas que o mínimo ou proposta que não é a de menor valor'
            using errcode = 'P0001';
        end if;
        new.valor_final := v_cot.valor_total;
        new.fornecedor_definido_em := now();

      -- Reabertura da cotação pelo comprador
      when old.status = 'aguardando_pedido' and new.status = 'em_cotacao' then
        if v_papel <> 'comprador' then
          raise exception 'Somente o comprador reabre a cotação' using errcode = '42501';
        end if;
        new.cotacao_vencedora_id := null;
        new.justificativa_escolha := null;
        new.valor_final := null;
        new.fornecedor_definido_em := null;

      -- 4 → 5. Pedido de compra emitido (disparado pela inclusão do pedido)
      when old.status = 'aguardando_pedido' and new.status = 'em_pedido' then
        if v_papel <> 'comprador' then
          raise exception 'Somente o comprador emite o pedido de compra' using errcode = '42501';
        end if;
        if not exists (select 1 from rg.pedidos where solicitacao_id = old.id and status not in ('reprovado', 'cancelado')) then
          raise exception 'Emita o pedido de compra antes de avançar' using errcode = 'P0001';
        end if;
        new.pedido_emitido_em := now();
        new.sla_concluido_em := coalesce(old.sla_concluido_em, now());

      -- Pedido reprovado ou cancelado: a cotação é reaberta
      when old.status = 'em_pedido' and new.status = 'em_cotacao' then
        if v_papel not in ('financeiro', 'diretoria', 'comprador', 'admin') then
          raise exception 'Operação não permitida para o seu perfil' using errcode = '42501';
        end if;
        if exists (select 1 from rg.pedidos where solicitacao_id = old.id and status not in ('reprovado', 'cancelado')) then
          raise exception 'Existe pedido de compra ativo para esta solicitação' using errcode = 'P0001';
        end if;
        new.cotacao_vencedora_id := null;
        new.justificativa_escolha := null;
        new.valor_final := null;
        new.fornecedor_definido_em := null;
        new.pedido_emitido_em := null;
        new.sla_concluido_em := null;

      -- 6/7. Recebimento (disparado pelo processamento do recebimento)
      when old.status in ('em_pedido', 'recebida_parcial') and new.status in ('recebida_parcial', 'concluida') then
        if not (v_papel = 'comprador' or old.solicitante_id = rg.usuario_atual_id()) then
          raise exception 'Somente quem abriu a solicitação registra o recebimento' using errcode = '42501';
        end if;
        select status into v_pedido from rg.pedidos
         where solicitacao_id = old.id and status not in ('reprovado', 'cancelado');
        if (new.status = 'concluida' and v_pedido is distinct from 'entregue')
           or (new.status = 'recebida_parcial' and v_pedido is distinct from 'entregue_parcial') then
          raise exception 'Situação do recebimento incompatível com o pedido de compra' using errcode = 'P0001';
        end if;

      else
        raise exception 'Transição inválida: % → %', old.status, new.status using errcode = 'P0001';
    end case;

    if new.status = 'aprovada' then
      new.aprovado_em := now();
    end if;
    if new.status = 'reprovada' and char_length(btrim(coalesce(new.motivo_reprovacao, ''))) < 10 then
      raise exception 'Informe o motivo da reprovação (mínimo 10 caracteres)' using errcode = 'P0001';
    end if;
    if new.status = 'devolvida' and char_length(btrim(coalesce(new.motivo_devolucao, ''))) < 10 then
      raise exception 'Informe o que precisa ser ajustado (mínimo 10 caracteres)' using errcode = 'P0001';
    end if;
    if new.status = 'cancelada' and char_length(btrim(coalesce(new.motivo_cancelamento, ''))) < 10 then
      raise exception 'Informe o motivo do cancelamento (mínimo 10 caracteres)' using errcode = 'P0001';
    end if;
    if new.status in ('reprovada', 'cancelada') then
      new.sla_concluido_em := coalesce(new.sla_concluido_em, now());
    end if;
    if rg.status_terminal(new.status) then
      new.finalizado_em := now();
    end if;
  end if;

  new.versao := old.versao + 1;
  return new;
end $$;;;

create or replace function rg.tg_solicitacao_movimentar() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_obs   text := rg.observacao_atual();
  v_link  text := '/solicitacoes/' || new.id;
  v_ref   text := new.codigo || ' — ' || new.titulo;
  v_nivel rg.nivel_aprovacao;
  v_dec   rg.decisao_aprovacao;
begin
  if tg_op = 'INSERT' then
    insert into rg.solicitacao_historico (solicitacao_id, autor_id, acao, status_de, status_para, observacao)
    values (new.id, rg.usuario_atual_id(), 'criacao', null, new.status::text,
            v_obs);
    if new.status = 'aguardando_gestor' then
      perform rg.notificar_setor('gestor', new.setor_codigo, 'Solicitação aguardando sua aprovação', v_ref, 'info', v_link);
    else
      perform rg.notificar_papel('diretoria', 'Solicitação aguardando aprovação da Diretoria', v_ref, 'info', v_link);
    end if;
    return null;
  end if;

  if new.status is not distinct from old.status then
    if (new.titulo, new.descricao, new.justificativa, new.tipo, new.urgencia, new.local_entrega, new.data_necessidade)
       is distinct from (old.titulo, old.descricao, old.justificativa, old.tipo, old.urgencia, old.local_entrega, old.data_necessidade) then
      insert into rg.solicitacao_historico (solicitacao_id, autor_id, acao, status_de, status_para, observacao)
      values (new.id, rg.usuario_atual_id(), 'edicao', old.status::text, new.status::text, coalesce(v_obs, 'Conteúdo ajustado pelo setor'));
    end if;
    return null;
  end if;

  insert into rg.solicitacao_historico (solicitacao_id, autor_id, acao, status_de, status_para, observacao)
  values (new.id, rg.usuario_atual_id(), 'mudanca_status', old.status::text, new.status::text,
          coalesce(v_obs, case new.status
            when 'reprovada' then new.motivo_reprovacao
            when 'devolvida' then new.motivo_devolucao
            when 'cancelada' then new.motivo_cancelamento
            when 'aguardando_pedido' then new.justificativa_escolha
          end));

  -- Registro formal das decisões de aprovação
  if old.status in ('aguardando_gestor', 'aguardando_diretoria')
     and new.status in ('aprovada', 'aguardando_diretoria', 'reprovada', 'devolvida') then
    v_nivel := case old.status when 'aguardando_gestor' then 'gestor' else 'diretoria' end;
    v_dec := case new.status when 'reprovada' then 'reprovado' when 'devolvida' then 'devolvido' else 'aprovado' end;
    insert into rg.aprovacoes (solicitacao_id, nivel, decisao, usuario_id, parecer, valor)
    values (new.id, v_nivel, v_dec, rg.usuario_atual_id(),
            coalesce(v_obs, new.motivo_reprovacao, new.motivo_devolucao), rg.valor_estimado(new.id));
  end if;

  case new.status
    when 'aguardando_diretoria' then
      perform rg.notificar(new.solicitante_id, 'Aprovada pelo gestor', v_ref || ' segue para aprovação da Diretoria.', 'info', v_link);
      perform rg.notificar_papel('diretoria', 'Solicitação aguardando aprovação da Diretoria', v_ref, 'info', v_link);
    when 'aprovada' then
      perform rg.notificar(new.solicitante_id, 'Solicitação aprovada', v_ref || ' foi encaminhada ao setor de Compras.', 'sucesso', v_link);
      perform rg.notificar_papel('comprador', 'Nova solicitação aprovada para cotação', v_ref, 'info', v_link);
    when 'devolvida' then
      perform rg.notificar(new.solicitante_id, 'Solicitação devolvida para ajustes', v_ref || ': ' || new.motivo_devolucao, 'alerta', v_link);
    when 'reprovada' then
      perform rg.notificar(new.solicitante_id, 'Solicitação reprovada', v_ref || ': ' || new.motivo_reprovacao, 'erro', v_link);
    when 'aguardando_gestor' then
      perform rg.notificar_setor('gestor', new.setor_codigo, 'Solicitação reenviada após ajustes', v_ref, 'info', v_link);
    when 'em_cotacao' then
      if old.status = 'aprovada' then
        perform rg.notificar(new.solicitante_id, 'Cotação iniciada', v_ref || ' está em cotação com fornecedores.', 'info', v_link);
      else
        perform rg.notificar(new.comprador_id, 'Cotação reaberta', v_ref || ': defina novamente o fornecedor.', 'alerta', v_link);
      end if;
    when 'aguardando_pedido' then
      perform rg.notificar(new.solicitante_id, 'Fornecedor definido', v_ref || ' aguarda a emissão do pedido de compra.', 'info', v_link);
    when 'em_pedido' then
      perform rg.notificar(new.solicitante_id, 'Pedido de compra emitido', v_ref, 'info', v_link);
    when 'recebida_parcial' then
      perform rg.notificar(new.solicitante_id, 'Recebimento parcial', v_ref || ' teve parte dos itens entregue.', 'info', v_link);
    when 'concluida' then
      perform rg.notificar(new.solicitante_id, 'Solicitação concluída', v_ref || ': itens recebidos e conferidos.', 'sucesso', v_link);
      perform rg.notificar(new.comprador_id, 'Solicitação concluída', v_ref, 'sucesso', v_link);
    when 'cancelada' then
      perform rg.notificar(new.solicitante_id, 'Solicitação cancelada', v_ref || ': ' || new.motivo_cancelamento, 'alerta', v_link);
      perform rg.notificar(new.comprador_id, 'Solicitação cancelada', v_ref, 'alerta', v_link);
    else
      null;
  end case;

  -- Ao reabrir a cotação, nenhuma proposta permanece selecionada
  if new.status = 'em_cotacao' and old.status in ('aguardando_pedido', 'em_pedido') then
    update rg.cotacoes set selecionada = false where solicitacao_id = new.id and selecionada;
  end if;
  return null;
end $$;;

create or replace function rg.tg_pedido_inserir() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_s   rg.solicitacoes;
  v_cot rg.cotacoes;
begin
  if rg.papel_atual() is distinct from 'comprador' then
    raise exception 'Somente o comprador emite pedidos de compra' using errcode = '42501';
  end if;
  select * into v_s from rg.solicitacoes where id = new.solicitacao_id;
  if v_s.status is distinct from 'aguardando_pedido' or v_s.cotacao_vencedora_id is null then
    raise exception 'Defina o fornecedor antes de emitir o pedido de compra' using errcode = 'P0001';
  end if;
  select * into v_cot from rg.cotacoes where id = v_s.cotacao_vencedora_id;
  -- Os valores do pedido vêm sempre da proposta vencedora
  new.cotacao_id := v_cot.id;
  new.fornecedor_id := v_cot.fornecedor_id;
  new.valor_itens := v_cot.valor_itens;
  new.frete := v_cot.frete;
  new.desconto := v_cot.desconto;
  new.valor_total := v_cot.valor_total;
  new.prazo_entrega_dias := v_cot.prazo_entrega_dias;
  new.condicoes_pagamento := coalesce(nullif(btrim(coalesce(new.condicoes_pagamento, '')), ''), v_cot.condicoes_pagamento);
  new.local_entrega := coalesce(nullif(btrim(coalesce(new.local_entrega, '')), ''), v_s.local_entrega);
  new.status := 'aprovado';
  new.comprador_id := rg.usuario_atual_id();
  new.exige_diretoria := false;
  new.codigo := 'PC-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-'
                || lpad(nextval('rg.pedido_codigo_seq')::text, 5, '0');
  new.aprovado_financeiro_por := null; new.aprovado_financeiro_em := null; new.parecer_financeiro := null;
  new.aprovado_diretoria_por := null; new.aprovado_diretoria_em := null; new.parecer_diretoria := null;
  new.enviado_por := null; new.enviado_em := null; new.data_prevista_entrega := null;
  new.motivo_reprovacao := null; new.motivo_cancelamento := null;
  new.encerrado_com_pendencia := false; new.justificativa_encerramento := null;
  new.atraso_notificado_em := null; new.concluido_em := null;
  new.versao := 1;
  new.criado_em := now();
  new.atualizado_em := now();
  return new;
end $$;;

create or replace function rg.tg_pedido_apos_inserir() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
begin
  insert into rg.pedido_itens (pedido_id, solicitacao_item_id, material_id, ordem, descricao, unidade, marca,
                               quantidade, valor_unitario)
  select new.id, si.id, si.material_id, si.ordem, si.descricao, si.unidade, ci.marca, ci.quantidade, ci.valor_unitario
    from rg.cotacao_itens ci
    join rg.solicitacao_itens si on si.id = ci.solicitacao_item_id
   where ci.cotacao_id = new.cotacao_id;

  update rg.solicitacoes set status = 'em_pedido' where id = new.solicitacao_id;

  insert into rg.solicitacao_historico (solicitacao_id, pedido_id, autor_id, acao, status_de, status_para, observacao)
  values (new.solicitacao_id, new.id, rg.usuario_atual_id(), 'pedido_emitido', null, new.status::text,
          'Pedido ' || new.codigo || ' emitido · ' || rg.moeda(new.valor_total));
  return null;
end $$;;


-- Pedidos e solicitações que aguardavam as aprovações extintas seguem adiante.
do $$
begin
  if exists (select 1 from rg.pedidos where status in ('aguardando_financeiro', 'aguardando_diretoria'))
     or exists (select 1 from rg.solicitacoes where status = 'aguardando_diretoria') then
    alter table rg.pedidos disable trigger user;
    alter table rg.solicitacoes disable trigger user;
    update rg.pedidos set status = 'aprovado' where status in ('aguardando_financeiro', 'aguardando_diretoria');
    update rg.solicitacoes set status = 'aprovada', aprovado_em = coalesce(aprovado_em, now())
     where status = 'aguardando_diretoria';
    alter table rg.pedidos enable trigger user;
    alter table rg.solicitacoes enable trigger user;
  end if;
  if exists (select 1 from rg.usuarios where papel in ('financeiro', 'diretoria')) then
    alter table rg.usuarios disable trigger user;
    update rg.usuarios set papel = 'auditoria' where papel in ('financeiro', 'diretoria');
    alter table rg.usuarios enable trigger user;
  end if;
end $$;
