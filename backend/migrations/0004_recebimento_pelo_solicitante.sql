-- =====================================================================
-- 0004 — O próprio solicitante registra o recebimento (perfil "Recebimento" descontinuado)
-- =====================================================================
-- O valor 'recebimento' permanece no tipo enumerado (PostgreSQL não remove valores), mas deixa de ser usado.

alter table rg.recebimentos alter column nota_fiscal drop not null;

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
        if v_uid = old.solicitante_id then
          raise exception 'Segregação de funções: o gestor não pode aprovar a própria solicitação' using errcode = 'P0001';
        end if;
        if new.status in ('aprovada', 'aguardando_diretoria') then
          new.aprovado_gestor_por := v_uid;
          new.aprovado_gestor_em := now();
          new.status := case when rg.valor_estimado(old.id) >= coalesce(rg.config_num('alcada_diretoria'), 0)
                             then 'aguardando_diretoria' else 'aprovada' end;
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
        new.status := case when old.aberta_por_gestor then 'aguardando_diretoria' else 'aguardando_gestor' end;
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
end $$;;

create or replace function rg.tg_pedido_validar() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_papel rg.papel_usuario := rg.papel_atual();
  v_uid   uuid := rg.usuario_atual_id();
  v_ops   text[] := array['atraso_notificado_em', 'atualizado_em'];
  v_edit  text[] := array['observacoes', 'data_prevista_entrega', 'condicoes_pagamento', 'local_entrega'];
  v_pendente boolean;
  v_recebido boolean;
begin
  if (to_jsonb(new) - v_ops) = (to_jsonb(old) - v_ops) then
    return new;
  end if;
  if new.codigo <> old.codigo or new.solicitacao_id <> old.solicitacao_id or new.cotacao_id <> old.cotacao_id
     or new.fornecedor_id <> old.fornecedor_id or new.comprador_id <> old.comprador_id
     or (new.valor_itens, new.frete, new.desconto, new.valor_total, new.prazo_entrega_dias, new.exige_diretoria)
        is distinct from (old.valor_itens, old.frete, old.desconto, old.valor_total, old.prazo_entrega_dias, old.exige_diretoria)
     or new.criado_em <> old.criado_em then
    raise exception 'Valores e dados estruturais do pedido não podem ser alterados' using errcode = 'P0001';
  end if;
  if old.status in ('entregue', 'reprovado', 'cancelado') then
    raise exception 'O pedido % já foi encerrado', old.codigo using errcode = 'P0001';
  end if;
  if v_papel is null or v_papel = 'auditoria' then
    raise exception 'Operação não permitida para o seu perfil' using errcode = '42501';
  end if;

  -- Controle definido pela máquina de estados
  new.aprovado_financeiro_por := old.aprovado_financeiro_por; new.aprovado_financeiro_em := old.aprovado_financeiro_em;
  new.aprovado_diretoria_por := old.aprovado_diretoria_por;   new.aprovado_diretoria_em := old.aprovado_diretoria_em;
  new.enviado_por := old.enviado_por; new.enviado_em := old.enviado_em;
  new.concluido_em := old.concluido_em;
  new.encerrado_com_pendencia := old.encerrado_com_pendencia;

  if new.status is not distinct from old.status then
    if (to_jsonb(new) - (v_ops || v_edit || array['versao'])) <> (to_jsonb(old) - (v_ops || v_edit || array['versao'])) then
      raise exception 'Alteração não permitida no pedido' using errcode = 'P0001';
    end if;
    if v_papel <> 'comprador' then
      raise exception 'Somente o comprador atualiza os dados do pedido' using errcode = '42501';
    end if;
    if (new.condicoes_pagamento, new.local_entrega) is distinct from (old.condicoes_pagamento, old.local_entrega)
       and old.status not in ('aguardando_financeiro', 'aguardando_diretoria') then
      raise exception 'Condições e local de entrega só podem ser alterados antes da aprovação' using errcode = 'P0001';
    end if;
    if new.data_prevista_entrega is distinct from old.data_prevista_entrega
       and old.status not in ('enviado', 'entregue_parcial') then
      raise exception 'A previsão de entrega é definida no envio ao fornecedor' using errcode = 'P0001';
    end if;
    new.versao := old.versao + 1;
    return new;
  end if;

  if new.status <> 'reprovado' then new.motivo_reprovacao := old.motivo_reprovacao; end if;
  if new.status <> 'cancelado' then new.motivo_cancelamento := old.motivo_cancelamento; end if;
  if not (old.status = 'aguardando_financeiro') then new.parecer_financeiro := old.parecer_financeiro; end if;
  if not (old.status = 'aguardando_diretoria') then new.parecer_diretoria := old.parecer_diretoria; end if;

  case
    when old.status = 'aguardando_financeiro' and new.status in ('aprovado', 'aguardando_diretoria', 'reprovado') then
      if v_papel <> 'financeiro' then
        raise exception 'Somente o Financeiro aprova pedidos nesta etapa' using errcode = '42501';
      end if;
      if new.status <> 'reprovado' then
        new.aprovado_financeiro_por := v_uid;
        new.aprovado_financeiro_em := now();
        new.status := case when old.exige_diretoria then 'aguardando_diretoria' else 'aprovado' end;
      end if;

    when old.status = 'aguardando_diretoria' and new.status in ('aprovado', 'reprovado') then
      if v_papel <> 'diretoria' then
        raise exception 'Somente a Diretoria aprova pedidos acima da alçada' using errcode = '42501';
      end if;
      if new.status = 'aprovado' then
        new.aprovado_diretoria_por := v_uid;
        new.aprovado_diretoria_em := now();
      end if;

    when old.status = 'aprovado' and new.status = 'enviado' then
      if v_papel <> 'comprador' then
        raise exception 'Somente o comprador envia o pedido ao fornecedor' using errcode = '42501';
      end if;
      new.enviado_por := v_uid;
      new.enviado_em := now();
      new.data_prevista_entrega := coalesce(new.data_prevista_entrega, rg.hoje() + old.prazo_entrega_dias);

    when old.status in ('aguardando_financeiro', 'aguardando_diretoria', 'aprovado', 'enviado') and new.status = 'cancelado' then
      if v_papel not in ('comprador', 'admin') then
        raise exception 'Somente Compras ou a administração cancela pedidos' using errcode = '42501';
      end if;
      if exists (select 1 from rg.pedido_itens where pedido_id = old.id and quantidade_recebida > 0) then
        raise exception 'Pedido com itens já recebidos não pode ser cancelado' using errcode = 'P0001';
      end if;
      if char_length(btrim(coalesce(new.motivo_cancelamento, ''))) < 10 then
        raise exception 'Informe o motivo do cancelamento (mínimo 10 caracteres)' using errcode = 'P0001';
      end if;

    when old.status in ('enviado', 'entregue_parcial') and new.status in ('entregue_parcial', 'entregue') then
      select exists (select 1 from rg.pedido_itens where pedido_id = old.id and quantidade_recebida < quantidade),
             exists (select 1 from rg.pedido_itens where pedido_id = old.id and quantidade_recebida > 0)
        into v_pendente, v_recebido;
      if v_papel in ('solicitante', 'gestor') and exists (
           select 1 from rg.solicitacoes where id = old.solicitacao_id and solicitante_id = rg.usuario_atual_id()) then
        if (new.status = 'entregue' and v_pendente) or (new.status = 'entregue_parcial' and (not v_pendente or not v_recebido)) then
          raise exception 'Situação incompatível com as quantidades recebidas' using errcode = 'P0001';
        end if;
      elsif v_papel = 'comprador' and old.status = 'entregue_parcial' and new.status = 'entregue' then
        if char_length(btrim(coalesce(new.justificativa_encerramento, ''))) < 10 then
          raise exception 'Justifique o encerramento com pendência (mínimo 10 caracteres)' using errcode = 'P0001';
        end if;
        new.encerrado_com_pendencia := v_pendente;
      else
        raise exception 'Somente quem abriu a solicitação registra o recebimento' using errcode = '42501';
      end if;
      if new.status = 'entregue' then
        new.concluido_em := now();
      end if;

    else
      raise exception 'Transição inválida do pedido: % → %', old.status, new.status using errcode = 'P0001';
  end case;

  if new.status = 'reprovado' and char_length(btrim(coalesce(new.motivo_reprovacao, ''))) < 10 then
    raise exception 'Informe o motivo da reprovação (mínimo 10 caracteres)' using errcode = 'P0001';
  end if;
  new.versao := old.versao + 1;
  return new;
end $$;;

create or replace function rg.tg_pedido_movimentar() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_obs  text := rg.observacao_atual();
  v_link text := '/pedidos/' || new.id;
  v_ref  text := new.codigo;
  v_s    rg.solicitacoes;
begin
  if new.status is not distinct from old.status then
    return null;
  end if;
  select * into v_s from rg.solicitacoes where id = new.solicitacao_id;
  v_ref := new.codigo || ' (' || v_s.codigo || ')';

  insert into rg.solicitacao_historico (solicitacao_id, pedido_id, autor_id, acao, status_de, status_para, observacao)
  values (new.solicitacao_id, new.id, rg.usuario_atual_id(), 'pedido_status', old.status::text, new.status::text,
          coalesce(v_obs, case new.status
            when 'reprovado' then new.motivo_reprovacao
            when 'cancelado' then new.motivo_cancelamento
            when 'entregue' then new.justificativa_encerramento
          end));

  if old.status in ('aguardando_financeiro', 'aguardando_diretoria') and new.status in ('aprovado', 'aguardando_diretoria', 'reprovado') then
    insert into rg.aprovacoes (solicitacao_id, pedido_id, nivel, decisao, usuario_id, parecer, valor)
    values (new.solicitacao_id, new.id,
            case old.status when 'aguardando_financeiro' then 'financeiro'::rg.nivel_aprovacao else 'diretoria' end,
            case new.status when 'reprovado' then 'reprovado'::rg.decisao_aprovacao else 'aprovado' end,
            rg.usuario_atual_id(),
            coalesce(v_obs, case when new.status = 'reprovado' then new.motivo_reprovacao
                                 when old.status = 'aguardando_financeiro' then new.parecer_financeiro
                                 else new.parecer_diretoria end),
            new.valor_total);
  end if;

  case new.status
    when 'aguardando_diretoria' then
      perform rg.notificar_papel('diretoria', 'Pedido aguardando aprovação da Diretoria', v_ref, 'info', v_link);
    when 'aprovado' then
      perform rg.notificar(new.comprador_id, 'Pedido aprovado', v_ref || ': envie ao fornecedor.', 'sucesso', v_link);
    when 'reprovado' then
      perform rg.notificar(new.comprador_id, 'Pedido reprovado', v_ref || ': ' || new.motivo_reprovacao, 'erro', v_link);
      update rg.solicitacoes set status = 'em_cotacao' where id = new.solicitacao_id and status = 'em_pedido';
    when 'cancelado' then
      update rg.solicitacoes set status = 'em_cotacao' where id = new.solicitacao_id and status = 'em_pedido';
    when 'enviado' then
      perform rg.notificar((select solicitante_id from rg.solicitacoes where id = new.solicitacao_id), 'Pedido enviado ao fornecedor',
        v_ref || ' · previsão ' || to_char(new.data_prevista_entrega, 'DD/MM/YYYY') || ' · confirme o recebimento quando chegar',
        'info', v_link);
      update rg.materiais m set ultimo_preco = pi.valor_unitario, ultima_compra_em = now()
        from rg.pedido_itens pi where pi.pedido_id = new.id and pi.material_id = m.id;
    when 'entregue_parcial' then
      update rg.solicitacoes set status = 'recebida_parcial' where id = new.solicitacao_id and status = 'em_pedido';
    when 'entregue' then
      update rg.solicitacoes set status = 'concluida' where id = new.solicitacao_id and status in ('em_pedido', 'recebida_parcial');
      perform rg.notificar(new.comprador_id, 'Pedido entregue', v_ref || ' foi recebido e conferido.', 'sucesso', v_link);
    else
      null;
  end case;
  return null;
end $$;;

create or replace function rg.tg_recebimento_inserir() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_p rg.pedidos;
  v_s rg.solicitacoes;
begin
  select * into v_p from rg.pedidos where id = new.pedido_id;
  select * into v_s from rg.solicitacoes where id = v_p.solicitacao_id;
  if v_s.id is null or v_s.solicitante_id is distinct from rg.usuario_atual_id() then
    raise exception 'Somente quem abriu a solicitação registra o recebimento' using errcode = '42501';
  end if;
  if v_p.status is null or v_p.status not in ('enviado', 'entregue_parcial') then
    raise exception 'O pedido precisa estar enviado ao fornecedor para registrar a entrega' using errcode = 'P0001';
  end if;
  new.solicitacao_id := v_p.solicitacao_id;
  new.recebido_por := rg.usuario_atual_id();
  new.recebido_em := now();
  new.criado_em := now();
  new.processado := false;
  new.situacao := 'conforme';
  new.codigo := 'RC-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-'
                || lpad(nextval('rg.recebimento_codigo_seq')::text, 5, '0');
  return new;
end $$;

create or replace function rg.processar_recebimento(p_recebimento uuid) returns rg.situacao_recebimento
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_r        rg.recebimentos;
  v_p        rg.pedidos;
  v_sit      rg.situacao_recebimento;
  v_total    numeric;
  v_aceito   numeric;
  v_diverg   boolean;
  v_pendente boolean;
  v_recebido boolean;
  v_novo     rg.status_pedido;
begin
  select * into v_r from rg.recebimentos where id = p_recebimento for update;
  if v_r.id is null or v_r.processado or v_r.recebido_por is distinct from rg.usuario_atual_id() then
    raise exception 'Recebimento inexistente, já processado ou de outro usuário' using errcode = 'P0001';
  end if;
  select coalesce(sum(quantidade_recebida), 0), coalesce(sum(quantidade_aceita), 0),
         coalesce(bool_or(quantidade_aceita < quantidade_recebida), false)
    into v_total, v_aceito, v_diverg
    from rg.recebimento_itens where recebimento_id = p_recebimento;
  if v_total = 0 then
    raise exception 'Informe a quantidade recebida de ao menos um item' using errcode = 'P0001';
  end if;
  v_sit := case when v_aceito = 0 then 'recusado' when v_diverg then 'divergente' else 'conforme' end;
  update rg.recebimentos set processado = true, situacao = v_sit where id = p_recebimento;

  select * into v_p from rg.pedidos where id = v_r.pedido_id for update;
  select exists (select 1 from rg.pedido_itens where pedido_id = v_p.id and quantidade_recebida < quantidade),
         exists (select 1 from rg.pedido_itens where pedido_id = v_p.id and quantidade_recebida > 0)
    into v_pendente, v_recebido;
  v_novo := case when not v_pendente then 'entregue' when v_recebido then 'entregue_parcial' else v_p.status end;

  insert into rg.solicitacao_historico (solicitacao_id, pedido_id, autor_id, acao, status_de, status_para, observacao)
  values (v_r.solicitacao_id, v_p.id, rg.usuario_atual_id(), 'recebimento', null, v_sit::text,
          v_r.codigo || coalesce(' · NF ' || v_r.nota_fiscal, '') || coalesce(' · ' || v_r.observacoes, ''));

  if v_novo is distinct from v_p.status then
    update rg.pedidos set status = v_novo where id = v_p.id;
  end if;
  if v_sit <> 'conforme' then
    perform rg.notificar(v_p.comprador_id, 'Recebimento com divergência',
      v_p.codigo || coalesce(' · NF ' || v_r.nota_fiscal, '') || ': ' || coalesce(v_r.observacoes, 'verifique a conferência'),
      'alerta', '/pedidos/' || v_p.id);
  end if;
  return v_sit;
end $$;;

create or replace function rg.tg_anexo_validar() returns trigger
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  v_s     rg.solicitacoes;
  v_papel rg.papel_usuario := rg.papel_atual();
  v_ok    boolean;
begin
  select * into v_s from rg.solicitacoes where id = new.solicitacao_id;
  if tg_op = 'UPDATE' then
    if (new.sha256, new.caminho, new.solicitacao_id, new.origem, new.enviado_por, new.nome_original, new.mime, new.tamanho,
        new.recebimento_id, new.criado_em)
       is distinct from (old.sha256, old.caminho, old.solicitacao_id, old.origem, old.enviado_por, old.nome_original, old.mime,
                         old.tamanho, old.recebimento_id, old.criado_em) then
      raise exception 'Metadados de integridade do anexo não podem ser alterados' using errcode = 'P0001';
    end if;
    if old.removido_em is not null then
      raise exception 'Anexo já removido' using errcode = 'P0001';
    end if;
    if exists (select 1 from rg.cotacoes where anexo_id = old.id) then
      raise exception 'O documento está vinculado a uma proposta' using errcode = 'P0001';
    end if;
    if old.origem = 'recebimento' then
      raise exception 'Documentos de recebimento não podem ser removidos' using errcode = 'P0001';
    end if;
    new.removido_por := rg.usuario_atual_id();
  else
    new.enviado_por := rg.usuario_atual_id();
    new.rodada := v_s.rodada;
    new.criado_em := now();
    new.removido_em := null;
    new.removido_por := null;
  end if;

  v_ok := case new.origem
    when 'solicitante' then v_papel in ('solicitante', 'gestor') and rg.setor_atual() = v_s.setor_codigo
                            and v_s.status in ('aguardando_gestor', 'aguardando_diretoria', 'devolvida')
    when 'comprador' then v_papel = 'comprador'
                          and v_s.status in ('aprovada', 'em_cotacao', 'aguardando_pedido', 'em_pedido', 'recebida_parcial')
    when 'recebimento' then v_papel in ('solicitante', 'gestor') and v_s.solicitante_id = rg.usuario_atual_id()
                            and v_s.status in ('em_pedido', 'recebida_parcial')
                            and (new.recebimento_id is null or exists (
                                  select 1 from rg.recebimentos r where r.id = new.recebimento_id and r.solicitacao_id = v_s.id))
  end;
  if not coalesce(v_ok, false) then
    raise exception 'Seu perfil não pode anexar ou remover documentos nesta etapa' using errcode = 'P0001';
  end if;

  if tg_op = 'INSERT' and new.origem = 'solicitante' then
    perform 1 from rg.solicitacoes where id = new.solicitacao_id for update;
    if (select count(*) from rg.anexos where solicitacao_id = new.solicitacao_id and origem = 'solicitante'
         and removido_em is null) >= 5 then
      raise exception 'Limite de 5 documentos do solicitante por solicitação atingido' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;;

create or replace function rg.processar_alertas() returns int
language plpgsql security definer
set search_path = rg, pg_temp
as $$
declare
  r     rg.solicitacoes;
  rp    rg.pedidos;
  v_qtd int := 0;
begin
  if not rg.eh_sistema() then
    raise exception 'Rotina exclusiva do agendador do sistema' using errcode = '42501';
  end if;
  for r in
    select * from rg.solicitacoes
     where not rg.status_terminal(status) and sla_concluido_em is null
       and sla_estouro_notificado_em is null and now() > sla_prazo_limite
     for update skip locked
  loop
    perform rg.notificar_responsavel(r, 'Prazo de atendimento estourado', 'erro');
    update rg.solicitacoes set sla_estouro_notificado_em = now(),
           sla_alerta_notificado_em = coalesce(sla_alerta_notificado_em, now())
     where id = r.id;
    v_qtd := v_qtd + 1;
  end loop;

  for r in
    select * from rg.solicitacoes
     where not rg.status_terminal(status) and sla_concluido_em is null
       and sla_alerta_notificado_em is null and now() <= sla_prazo_limite
       and sla_prazo_limite - now() < interval '24 hours'
     for update skip locked
  loop
    perform rg.notificar_responsavel(r, 'Prazo de atendimento vence em menos de 24 h', 'alerta');
    update rg.solicitacoes set sla_alerta_notificado_em = now() where id = r.id;
    v_qtd := v_qtd + 1;
  end loop;

  for rp in
    select * from rg.pedidos
     where status in ('enviado', 'entregue_parcial') and data_prevista_entrega < rg.hoje()
       and atraso_notificado_em is null
     for update skip locked
  loop
    perform rg.notificar(rp.comprador_id, 'Entrega em atraso', rp.codigo || ' · previsão ' ||
      to_char(rp.data_prevista_entrega, 'DD/MM/YYYY'), 'erro', '/pedidos/' || rp.id);
    perform rg.notificar((select solicitante_id from rg.solicitacoes where id = rp.solicitacao_id), 'Entrega em atraso',
      rp.codigo, 'alerta', '/pedidos/' || rp.id);
    update rg.pedidos set atraso_notificado_em = now() where id = rp.id;
    v_qtd := v_qtd + 1;
  end loop;
  return v_qtd;
end $$;;


-- Políticas: o solicitante (e o gestor que abriu a solicitação) registra o recebimento; a regra fina fica nos gatilhos.
drop policy recebimentos_insercao on rg.recebimentos;
create policy recebimentos_insercao on rg.recebimentos for insert to rg_app with check (
  (select rg.papel_atual()) in ('solicitante', 'gestor')
);
drop policy rec_itens_insercao on rg.recebimento_itens;
create policy rec_itens_insercao on rg.recebimento_itens for insert to rg_app with check (
  (select rg.papel_atual()) in ('solicitante', 'gestor')
);
drop policy anexos_insercao on rg.anexos;
create policy anexos_insercao on rg.anexos for insert to rg_app with check (
  enviado_por = (select rg.usuario_atual_id())
  and (select rg.papel_atual()) in ('solicitante', 'gestor', 'comprador')
  and exists (select 1 from rg.solicitacoes s where s.id = anexos.solicitacao_id)
);

-- A visão de pedidos passa a expor quem abriu a solicitação (apenas acrescenta coluna ao final).
create or replace view rg.v_pedidos with (security_invoker = true) as
  select p.*,
         s.codigo as solicitacao_codigo,
         s.titulo as solicitacao_titulo,
         s.setor_codigo,
         s.urgencia,
         st.nome as setor_nome,
         st.cor as setor_cor,
         f.razao_social as fornecedor_nome,
         f.nome_fantasia as fornecedor_fantasia,
         f.cnpj as fornecedor_cnpj,
         uc.nome as comprador_nome,
         us.nome as solicitante_nome,
         (select count(*) from rg.pedido_itens i where i.pedido_id = p.id) as itens_qtd,
         (select coalesce(round(100 * sum(least(i.quantidade_recebida, i.quantidade)) / nullif(sum(i.quantidade), 0)), 0)
            from rg.pedido_itens i where i.pedido_id = p.id) as percentual_recebido,
         (p.status in ('enviado', 'entregue_parcial') and p.data_prevista_entrega < rg.hoje()) as atrasado,
         case when p.status in ('enviado', 'entregue_parcial') and p.data_prevista_entrega < rg.hoje()
              then rg.hoje() - p.data_prevista_entrega else 0 end as dias_atraso,
         s.solicitante_id
    from rg.pedidos p
    join rg.solicitacoes s on s.id = p.solicitacao_id
    join rg.setores st on st.codigo = s.setor_codigo
    join rg.fornecedores f on f.id = p.fornecedor_id
    left join rg.v_usuarios_publico uc on uc.id = p.comprador_id
    left join rg.v_usuarios_publico us on us.id = s.solicitante_id;

-- Usuários que tinham o perfil descontinuado passam a solicitantes.
do $$
begin
  if exists (select 1 from rg.usuarios where papel = 'recebimento') then
    alter table rg.usuarios disable trigger user;
    update rg.usuarios set papel = 'solicitante' where papel = 'recebimento';
    alter table rg.usuarios enable trigger user;
  end if;
end $$;
