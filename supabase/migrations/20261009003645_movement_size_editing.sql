create or replace function public.editar_movimento_v2(
  p_id text,
  p_tamanho text,
  p_qtd integer,
  p_valor numeric,
  p_percentual_pago numeric,
  p_motivo_edicao text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_usuario uuid:=auth.uid();
  v_mov public.movements%rowtype;
  v_produto public.products%rowtype;
  v_tamanho text:=btrim(coalesce(p_tamanho,''));
  v_motivo text:=btrim(coalesce(p_motivo_edicao,''));
  v_saldo_sem bigint;
  v_saldo_destino bigint;
  v_saldo_novo bigint;
  v_lock_antigo bigint;
  v_lock_novo bigint;
begin
  if v_usuario is null then raise exception 'Usuário não autenticado'; end if;
  if v_tamanho='' then raise exception 'Informe o tamanho'; end if;
  if p_qtd is null or p_qtd<=0 then raise exception 'A quantidade deve ser maior que zero'; end if;
  if p_valor is null or p_valor<0 then raise exception 'O valor não pode ser negativo'; end if;
  if v_motivo='' then raise exception 'Informe o motivo da correção'; end if;

  select * into v_mov from public.movements where id=p_id for update;
  if not found then raise exception 'Movimentação não encontrada'; end if;
  if v_mov.cancelado_em is not null then raise exception 'Movimentações canceladas não podem ser editadas'; end if;

  select * into v_produto from public.products where codigo=v_mov.codigo;
  if not found then raise exception 'Produto não encontrado'; end if;
  if not (v_tamanho=any(v_produto.tamanhos)) then raise exception 'Tamanho não pertence ao produto'; end if;
  if v_mov.tipo='Saída' and p_percentual_pago not in (0.00,50.00,100.00) then raise exception 'Selecione pagamento de 0%%, 50%% ou 100%%'; end if;

  v_lock_antigo:=hashtextextended(v_mov.codigo||'|'||v_mov.tamanho,0);
  v_lock_novo:=hashtextextended(v_mov.codigo||'|'||v_tamanho,0);
  perform pg_advisory_xact_lock(least(v_lock_antigo,v_lock_novo));
  if v_lock_antigo<>v_lock_novo then perform pg_advisory_xact_lock(greatest(v_lock_antigo,v_lock_novo)); end if;

  if v_tamanho=v_mov.tamanho then
    select coalesce(sum(case when tipo='Entrada' then qtd else -qtd end),0)
      into v_saldo_sem from public.movements
      where codigo=v_mov.codigo and tamanho=v_mov.tamanho and cancelado_em is null and id<>p_id;
    v_saldo_novo:=v_saldo_sem+case when v_mov.tipo='Entrada' then p_qtd else -p_qtd end;
    if v_saldo_novo<0 then raise exception 'A correção deixaria o estoque negativo. Saldo máximo disponível: %',v_saldo_sem; end if;
  else
    select coalesce(sum(case when tipo='Entrada' then qtd else -qtd end),0)
      into v_saldo_sem from public.movements
      where codigo=v_mov.codigo and tamanho=v_mov.tamanho and cancelado_em is null and id<>p_id;
    if v_saldo_sem<0 then raise exception 'A troca deixaria o tamanho anterior com saldo negativo'; end if;

    select coalesce(sum(case when tipo='Entrada' then qtd else -qtd end),0)
      into v_saldo_destino from public.movements
      where codigo=v_mov.codigo and tamanho=v_tamanho and cancelado_em is null;
    v_saldo_novo:=v_saldo_destino+case when v_mov.tipo='Entrada' then p_qtd else -p_qtd end;
    if v_saldo_novo<0 then raise exception 'Estoque insuficiente no tamanho %. Disponível: %, solicitado: %',v_tamanho,v_saldo_destino,p_qtd; end if;
  end if;

  insert into public.movement_edits(movement_id,valores_anteriores,valores_novos,motivo,edited_by)
  values(p_id,
    jsonb_build_object('tamanho',v_mov.tamanho,'qtd',v_mov.qtd,'valor',v_mov.valor,'percentual_pago',v_mov.percentual_pago),
    jsonb_build_object('tamanho',v_tamanho,'qtd',p_qtd,'valor',p_valor::numeric(12,2),'percentual_pago',case when v_mov.tipo='Saída' then p_percentual_pago else null end),
    v_motivo,v_usuario);

  update public.movements set
    tamanho=v_tamanho,
    qtd=p_qtd,
    valor=p_valor::numeric(12,2),
    percentual_pago=case when tipo='Saída' then p_percentual_pago else null end,
    editado_em=now(),
    editado_por=v_usuario,
    motivo_edicao=v_motivo
  where id=p_id;

  return jsonb_build_object('success',true,'id',p_id,'tamanho_anterior',v_mov.tamanho,'tamanho_novo',v_tamanho,'saldo_destino',v_saldo_novo);
end $function$;

revoke execute on function public.editar_movimento_v2(text,text,integer,numeric,numeric,text) from public,anon;
grant execute on function public.editar_movimento_v2(text,text,integer,numeric,numeric,text) to authenticated;