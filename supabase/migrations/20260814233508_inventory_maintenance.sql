-- Chile Customize inventory maintenance (2026-08-14).
-- Idempotent, history-preserving, and compatible with the existing RPC names.

alter table public.products
  add column if not exists ativo boolean;

update public.products set ativo = true where ativo is null;

drop view if exists public.sales_summary;
drop view if exists public.stock_balances;

alter table public.products
  alter column ativo set default true,
  alter column ativo set not null,
  alter column custo type numeric(12,2) using custo::numeric(12,2),
  alter column venda type numeric(12,2) using venda::numeric(12,2);

alter table public.movements
  alter column valor type numeric(12,2) using valor::numeric(12,2),
  alter column custo_unitario type numeric(12,2) using custo_unitario::numeric(12,2);

create view public.stock_balances
with (security_invoker = true)
as
select codigo, tamanho,
       sum(case when tipo='Entrada' then qtd else -qtd end) as saldo
from public.movements
where cancelado_em is null
group by codigo, tamanho;

create view public.sales_summary
with (security_invoker = true)
as
select coalesce(sum(valor * qtd::numeric),0::numeric) as total_vendas,
       coalesce(sum((valor-custo_unitario) * qtd::numeric),0::numeric) as lucro_estimado
from public.movements
where tipo='Saída' and cancelado_em is null;

create index if not exists movements_active_recent_idx
  on public.movements (created_at desc, ts desc)
  where cancelado_em is null;

create index if not exists movements_cancelled_recent_idx
  on public.movements (cancelado_em desc)
  where cancelado_em is not null;

create index if not exists products_ativo_codigo_idx
  on public.products (ativo, codigo);

create or replace function public.registrar_movimento(
  p_id text,
  p_ts bigint,
  p_data date,
  p_codigo text,
  p_tamanho text,
  p_tipo text,
  p_qtd integer,
  p_valor numeric,
  p_motivo text default '',
  p_obs text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_saldo bigint;
  v_produto public.products%rowtype;
  v_chave_lock bigint;
  v_usuario uuid;
begin
  v_usuario := auth.uid();
  if v_usuario is null then raise exception 'Usuário não autenticado'; end if;
  if p_id is null or btrim(p_id) = '' then raise exception 'Identificador do movimento não informado'; end if;
  if p_tipo not in ('Entrada', 'Saída') then raise exception 'Tipo de movimento inválido'; end if;
  if p_qtd is null or p_qtd <= 0 then raise exception 'A quantidade deve ser maior que zero'; end if;
  if p_valor is null or p_valor < 0 then raise exception 'O valor não pode ser negativo'; end if;
  if p_data is null then raise exception 'Data não informada'; end if;
  if p_ts is null or p_ts <= 0 then raise exception 'Data e hora do movimento inválidas'; end if;
  if p_codigo is null or btrim(p_codigo) = '' then raise exception 'Código do produto não informado'; end if;
  if p_tamanho is null or btrim(p_tamanho) = '' then raise exception 'Tamanho não informado'; end if;

  select * into v_produto from public.products where codigo = p_codigo;
  if not found then raise exception 'Produto não encontrado'; end if;
  if not v_produto.ativo then raise exception 'Produto arquivado; reative-o antes de lançar movimentos'; end if;
  if not (p_tamanho = any(v_produto.tamanhos)) then raise exception 'Tamanho não pertence ao produto'; end if;

  v_chave_lock := hashtextextended(p_codigo || '|' || p_tamanho, 0);
  perform pg_advisory_xact_lock(v_chave_lock);
  select coalesce(sum(case when tipo='Entrada' then qtd else -qtd end),0)
    into v_saldo
    from public.movements
   where codigo=p_codigo and tamanho=p_tamanho and cancelado_em is null;
  if p_tipo='Saída' and p_qtd > v_saldo then
    raise exception 'Estoque insuficiente. Disponível: %, solicitado: %', v_saldo, p_qtd;
  end if;

  insert into public.movements
    (id,ts,data,codigo,tamanho,tipo,qtd,valor,motivo,obs,custo_unitario,created_at,created_by)
  values
    (p_id,p_ts,p_data,p_codigo,p_tamanho,p_tipo,p_qtd,p_valor::numeric(12,2),
     coalesce(p_motivo,''),coalesce(p_obs,''),
     case when p_tipo='Saída' then coalesce(v_produto.custo,0) else 0 end,
     now(),v_usuario);

  return jsonb_build_object('success',true,'id',p_id,'saldo_anterior',v_saldo,
    'saldo_novo',case when p_tipo='Entrada' then v_saldo+p_qtd else v_saldo-p_qtd end);
end;
$$;

create or replace function public.cancelar_movimento(p_id text, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movimento public.movements%rowtype;
  v_usuario uuid;
  v_motivo text := btrim(coalesce(p_motivo,''));
begin
  v_usuario := auth.uid();
  if v_usuario is null then raise exception 'Usuário não autenticado'; end if;
  if v_motivo = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  select * into v_movimento from public.movements where id=p_id for update;
  if not found then raise exception 'Movimentação não encontrada'; end if;
  if v_movimento.cancelado_em is not null then
    return jsonb_build_object('success',true,'already_cancelled',true,'id',p_id);
  end if;
  update public.movements
     set cancelado_em=now(), cancelado_por=v_usuario, motivo_cancelamento=v_motivo
   where id=p_id;
  return jsonb_build_object('success',true,'already_cancelled',false,'id',p_id,
    'codigo',v_movimento.codigo,'tamanho',v_movimento.tamanho,
    'tipo',v_movimento.tipo,'qtd',v_movimento.qtd);
end;
$$;

revoke all on function public.registrar_movimento(text,bigint,date,text,text,text,integer,numeric,text,text) from public, anon;
grant execute on function public.registrar_movimento(text,bigint,date,text,text,text,integer,numeric,text,text) to authenticated;
revoke all on function public.cancelar_movimento(text) from public, anon;
grant execute on function public.cancelar_movimento(text) to authenticated;
revoke all on function public.cancelar_movimento(text,text) from public, anon;
grant execute on function public.cancelar_movimento(text,text) to authenticated;

revoke all privileges on table public.movements from anon, authenticated;
grant select on table public.movements to authenticated;

revoke all privileges on table public.products from anon, authenticated;
grant select, insert, update on table public.products to authenticated;

drop policy if exists "somente logado - produtos" on public.products;
drop policy if exists "somente logado - leitura produtos" on public.products;
drop policy if exists "somente logado - cria produtos" on public.products;
drop policy if exists "somente logado - atualiza produtos" on public.products;
create policy "somente logado - leitura produtos" on public.products for select to authenticated using (true);
create policy "somente logado - cria produtos" on public.products for insert to authenticated with check (true);
create policy "somente logado - atualiza produtos" on public.products for update to authenticated using (true) with check (true);

revoke all privileges on table public.stock_balances, public.sales_summary from anon;
grant select on table public.stock_balances, public.sales_summary to authenticated;

