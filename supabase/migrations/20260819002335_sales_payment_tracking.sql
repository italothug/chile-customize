alter table public.movements add column if not exists percentual_pago numeric(5,2);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='movements_percentual_pago_valid'
      and conrelid='public.movements'::regclass
  ) then
    alter table public.movements add constraint movements_percentual_pago_valid
      check (percentual_pago is null or percentual_pago in (50.00,100.00));
  end if;
end $$;

create index if not exists movements_vendas_mes_idx
  on public.movements (data desc,created_at desc)
  include (valor,qtd,percentual_pago,codigo,tamanho)
  where tipo='Saída' and cancelado_em is null;

create or replace function public.registrar_movimento(
  p_id text,p_ts bigint,p_data date,p_codigo text,p_tamanho text,p_tipo text,p_qtd integer,
  p_valor numeric,p_motivo text,p_obs text,p_percentual_pago numeric
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
  if p_tipo='Saída' and p_percentual_pago not in (50.00,100.00) then
    raise exception 'Selecione pagamento de 50%% ou 100%%';
  end if;
  select public.registrar_movimento(
    p_id,p_ts,p_data,p_codigo,p_tamanho,p_tipo,p_qtd,p_valor,p_motivo,p_obs
  ) into v_result;
  update public.movements
     set percentual_pago=case when p_tipo='Saída' then p_percentual_pago else null end
   where id=p_id;
  return v_result||jsonb_build_object(
    'percentual_pago',case when p_tipo='Saída' then p_percentual_pago else null end
  );
end $$;

create or replace function public.atualizar_pagamento_venda(
  p_id text,p_percentual_pago numeric
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_usuario uuid;
  v_movimento public.movements%rowtype;
begin
  v_usuario:=auth.uid();
  if v_usuario is null then raise exception 'Usuário não autenticado'; end if;
  if p_percentual_pago not in (50.00,100.00) then
    raise exception 'Selecione pagamento de 50%% ou 100%%';
  end if;
  select * into v_movimento from public.movements where id=p_id for update;
  if not found then raise exception 'Venda não encontrada'; end if;
  if v_movimento.tipo<>'Saída' then raise exception 'A movimentação informada não é uma venda'; end if;
  if v_movimento.cancelado_em is not null then raise exception 'Não é possível atualizar uma venda cancelada'; end if;
  update public.movements set percentual_pago=p_percentual_pago where id=p_id;
  return jsonb_build_object(
    'success',true,'id',p_id,'percentual_pago',p_percentual_pago,'atualizado_por',v_usuario
  );
end $$;

revoke all on function public.registrar_movimento(
  text,bigint,date,text,text,text,integer,numeric,text,text,numeric
) from public,anon;
grant execute on function public.registrar_movimento(
  text,bigint,date,text,text,text,integer,numeric,text,text,numeric
) to authenticated;

revoke all on function public.atualizar_pagamento_venda(text,numeric) from public,anon;
grant execute on function public.atualizar_pagamento_venda(text,numeric) to authenticated;

