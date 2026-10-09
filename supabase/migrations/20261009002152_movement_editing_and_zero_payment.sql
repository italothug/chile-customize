alter table public.movements
  add column if not exists editado_em timestamptz,
  add column if not exists editado_por uuid references auth.users(id) on delete set null,
  add column if not exists motivo_edicao text;

alter table public.movements drop constraint if exists movements_percentual_pago_valid;
alter table public.movements add constraint movements_percentual_pago_valid
  check (percentual_pago is null or percentual_pago in (0.00,50.00,100.00));

create table if not exists public.movement_edits (
  id bigint generated always as identity primary key,
  movement_id text not null references public.movements(id) on delete restrict,
  valores_anteriores jsonb not null,
  valores_novos jsonb not null,
  motivo text not null check (btrim(motivo) <> ''),
  edited_at timestamptz not null default now(),
  edited_by uuid references auth.users(id) on delete set null
);
create index if not exists movement_edits_movement_time_idx on public.movement_edits(movement_id,edited_at desc);
alter table public.movement_edits enable row level security;
revoke all on table public.movement_edits from anon;
revoke insert,update,delete,truncate,references,trigger on table public.movement_edits from authenticated;
grant select on table public.movement_edits to authenticated;
drop policy if exists movement_edits_authenticated_select on public.movement_edits;
create policy movement_edits_authenticated_select on public.movement_edits for select to authenticated using ((select auth.uid()) is not null);

create or replace function public.editar_movimento(
  p_id text,p_qtd integer,p_valor numeric,p_percentual_pago numeric,p_motivo_edicao text
) returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_usuario uuid:=auth.uid();
  v_mov public.movements%rowtype;
  v_saldo_sem bigint;
  v_saldo_novo bigint;
  v_motivo text:=btrim(coalesce(p_motivo_edicao,''));
begin
  if v_usuario is null then raise exception 'Usuário não autenticado'; end if;
  if p_qtd is null or p_qtd<=0 then raise exception 'A quantidade deve ser maior que zero'; end if;
  if p_valor is null or p_valor<0 then raise exception 'O valor não pode ser negativo'; end if;
  if v_motivo='' then raise exception 'Informe o motivo da correção'; end if;

  select * into v_mov from public.movements where id=p_id for update;
  if not found then raise exception 'Movimentação não encontrada'; end if;
  if v_mov.cancelado_em is not null then raise exception 'Movimentações canceladas não podem ser editadas'; end if;
  if v_mov.tipo='Saída' and p_percentual_pago not in (0.00,50.00,100.00) then raise exception 'Selecione pagamento de 0%%, 50%% ou 100%%'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_mov.codigo||'|'||v_mov.tamanho,0));
  select coalesce(sum(case when tipo='Entrada' then qtd else -qtd end),0)
    into v_saldo_sem from public.movements
    where codigo=v_mov.codigo and tamanho=v_mov.tamanho and cancelado_em is null and id<>p_id;
  v_saldo_novo:=v_saldo_sem+case when v_mov.tipo='Entrada' then p_qtd else -p_qtd end;
  if v_saldo_novo<0 then raise exception 'A correção deixaria o estoque negativo. Saldo máximo disponível: %',v_saldo_sem; end if;

  insert into public.movement_edits(movement_id,valores_anteriores,valores_novos,motivo,edited_by)
  values(p_id,
    jsonb_build_object('qtd',v_mov.qtd,'valor',v_mov.valor,'percentual_pago',v_mov.percentual_pago),
    jsonb_build_object('qtd',p_qtd,'valor',p_valor::numeric(12,2),'percentual_pago',case when v_mov.tipo='Saída' then p_percentual_pago else null end),
    v_motivo,v_usuario);

  update public.movements set
    qtd=p_qtd,valor=p_valor::numeric(12,2),
    percentual_pago=case when tipo='Saída' then p_percentual_pago else null end,
    editado_em=now(),editado_por=v_usuario,motivo_edicao=v_motivo
  where id=p_id;

  return jsonb_build_object('success',true,'id',p_id,'saldo_novo',v_saldo_novo);
end $function$;

revoke execute on function public.editar_movimento(text,integer,numeric,numeric,text) from public,anon;
grant execute on function public.editar_movimento(text,integer,numeric,numeric,text) to authenticated;

create or replace function public.atualizar_pagamento_venda(p_id text,p_percentual_pago numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_usuario uuid:=auth.uid();v_mov public.movements%rowtype;v_result jsonb;
begin
 if v_usuario is null then raise exception 'Usuário não autenticado';end if;
 if p_percentual_pago not in (0.00,50.00,100.00) then raise exception 'Selecione pagamento de 0%%, 50%% ou 100%%';end if;
 select * into v_mov from public.movements where id=p_id;
 if not found then raise exception 'Venda não encontrada';end if;
 if v_mov.tipo<>'Saída' then raise exception 'A movimentação informada não é uma venda';end if;
 select public.editar_movimento(p_id,v_mov.qtd,v_mov.valor,p_percentual_pago,'Atualização de pagamento') into v_result;
 return v_result||jsonb_build_object('percentual_pago',p_percentual_pago,'atualizado_por',v_usuario);
end $function$;

create or replace function public.registrar_movimento(
 p_id text,p_ts bigint,p_data date,p_codigo text,p_tamanho text,p_tipo text,p_qtd integer,p_valor numeric,p_motivo text,p_obs text,p_percentual_pago numeric
) returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Usuário não autenticado';end if;
 if p_tipo='Saída' and p_percentual_pago not in (0.00,50.00,100.00) then raise exception 'Selecione pagamento de 0%%, 50%% ou 100%%';end if;
 select public.registrar_movimento(p_id,p_ts,p_data,p_codigo,p_tamanho,p_tipo,p_qtd,p_valor,p_motivo,p_obs) into v_result;
 update public.movements set percentual_pago=case when p_tipo='Saída' then p_percentual_pago else null end where id=p_id;
 return v_result||jsonb_build_object('percentual_pago',case when p_tipo='Saída' then p_percentual_pago else null end);
end $function$;

revoke execute on function public.atualizar_pagamento_venda(text,numeric) from public,anon;
grant execute on function public.atualizar_pagamento_venda(text,numeric) to authenticated;
revoke execute on function public.registrar_movimento(text,bigint,date,text,text,text,integer,numeric,text,text,numeric) from public,anon;
grant execute on function public.registrar_movimento(text,bigint,date,text,text,text,integer,numeric,text,text,numeric) to authenticated;