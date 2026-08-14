begin;

-- Preserve financial and operational history without breaking existing rows.
alter table public.movements
  add column if not exists custo_unitario numeric,
  add column if not exists created_at timestamptz,
  add column if not exists created_by uuid,
  add column if not exists cancelado_em timestamptz,
  add column if not exists cancelado_por uuid,
  add column if not exists motivo_cancelamento text;

update public.movements m
set custo_unitario = case
  when m.tipo = 'Saída' then coalesce(p.custo, 0)
  else 0
end
from public.products p
where p.codigo = m.codigo
  and m.custo_unitario is null;

update public.movements
set custo_unitario = 0
where custo_unitario is null;

update public.movements
set created_at = to_timestamp(ts / 1000.0)
where created_at is null;

alter table public.movements
  alter column custo_unitario set default 0,
  alter column custo_unitario set not null,
  alter column created_at set default now(),
  alter column created_at set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'movements_created_by_fkey'
      and conrelid = 'public.movements'::regclass
  ) then
    alter table public.movements
      add constraint movements_created_by_fkey
      foreign key (created_by) references auth.users(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'movements_cancelado_por_fkey'
      and conrelid = 'public.movements'::regclass
  ) then
    alter table public.movements
      add constraint movements_cancelado_por_fkey
      foreign key (cancelado_por) references auth.users(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'movements_qtd_positive'
      and conrelid = 'public.movements'::regclass
  ) then
    alter table public.movements
      add constraint movements_qtd_positive check (qtd > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'movements_valor_nonnegative'
      and conrelid = 'public.movements'::regclass
  ) then
    alter table public.movements
      add constraint movements_valor_nonnegative check (valor >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'movements_custo_nonnegative'
      and conrelid = 'public.movements'::regclass
  ) then
    alter table public.movements
      add constraint movements_custo_nonnegative check (custo_unitario >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'products_min_nonnegative'
      and conrelid = 'public.products'::regclass
  ) then
    alter table public.products
      add constraint products_min_nonnegative check (min >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'products_custo_nonnegative'
      and conrelid = 'public.products'::regclass
  ) then
    alter table public.products
      add constraint products_custo_nonnegative check (custo >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'products_venda_nonnegative'
      and conrelid = 'public.products'::regclass
  ) then
    alter table public.products
      add constraint products_venda_nonnegative check (venda >= 0);
  end if;
end
$$;

create index if not exists movements_codigo_idx
  on public.movements (codigo);

create index if not exists movements_saldo_ativo_idx
  on public.movements (codigo, tamanho, tipo)
  include (qtd)
  where cancelado_em is null;

create index if not exists movements_cancelado_por_idx
  on public.movements (cancelado_por)
  where cancelado_por is not null;

create index if not exists movements_created_by_idx
  on public.movements (created_by)
  where created_by is not null;

create or replace view public.stock_balances
with (security_invoker = true)
as
select
  codigo,
  tamanho,
  sum(case when tipo = 'Entrada' then qtd else -qtd end) as saldo
from public.movements
where cancelado_em is null
group by codigo, tamanho;

create or replace view public.sales_summary
with (security_invoker = true)
as
select
  coalesce(sum(m.valor * m.qtd::numeric), 0::numeric) as total_vendas,
  coalesce(sum((m.valor - m.custo_unitario) * m.qtd::numeric), 0::numeric) as lucro_estimado
from public.movements m
where m.tipo = 'Saída'
  and m.cancelado_em is null;

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
  v_saldo numeric;
  v_produto public.products%rowtype;
  v_chave_lock bigint;
  v_usuario uuid;
begin
  v_usuario := auth.uid();
  if v_usuario is null then
    raise exception 'Usuário não autenticado';
  end if;

  if p_id is null or trim(p_id) = '' then
    raise exception 'Identificador do movimento não informado';
  end if;

  if p_tipo not in ('Entrada', 'Saída') then
    raise exception 'Tipo de movimento inválido';
  end if;

  if p_qtd is null or p_qtd <= 0 then
    raise exception 'A quantidade deve ser maior que zero';
  end if;

  if p_valor is null or p_valor < 0 then
    raise exception 'O valor não pode ser negativo';
  end if;

  if p_data is null then
    raise exception 'Data não informada';
  end if;

  if p_ts is null or p_ts <= 0 then
    raise exception 'Data e hora do movimento inválidas';
  end if;

  if p_codigo is null or trim(p_codigo) = '' then
    raise exception 'Código do produto não informado';
  end if;

  if p_tamanho is null or trim(p_tamanho) = '' then
    raise exception 'Tamanho não informado';
  end if;

  select *
  into v_produto
  from public.products
  where codigo = p_codigo;

  if not found then
    raise exception 'Produto não encontrado';
  end if;

  if not (p_tamanho = any(v_produto.tamanhos)) then
    raise exception 'Tamanho não pertence ao produto';
  end if;

  v_chave_lock := hashtextextended(p_codigo || '|' || p_tamanho, 0);
  perform pg_advisory_xact_lock(v_chave_lock);

  select coalesce(sum(
    case
      when tipo = 'Entrada' then qtd
      when tipo = 'Saída' then -qtd
      else 0
    end
  ), 0)
  into v_saldo
  from public.movements
  where codigo = p_codigo
    and tamanho = p_tamanho
    and cancelado_em is null;

  if p_tipo = 'Saída' and p_qtd > v_saldo then
    raise exception 'Estoque insuficiente. Disponível: %, solicitado: %', v_saldo, p_qtd;
  end if;

  insert into public.movements (
    id, ts, data, codigo, tamanho, tipo, qtd, valor, motivo, obs,
    custo_unitario, created_at, created_by
  ) values (
    p_id, p_ts, p_data, p_codigo, p_tamanho, p_tipo, p_qtd,
    p_valor, coalesce(p_motivo, ''), coalesce(p_obs, ''),
    case when p_tipo = 'Saída' then coalesce(v_produto.custo, 0) else 0 end,
    now(), v_usuario
  );

  return jsonb_build_object(
    'success', true,
    'id', p_id,
    'saldo_anterior', v_saldo,
    'saldo_novo', case
      when p_tipo = 'Entrada' then v_saldo + p_qtd
      else v_saldo - p_qtd
    end
  );
end;
$$;

create or replace function public.cancelar_movimento(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movimento public.movements%rowtype;
  v_usuario uuid;
begin
  v_usuario := auth.uid();
  if v_usuario is null then
    raise exception 'Usuário não autenticado';
  end if;

  select *
  into v_movimento
  from public.movements
  where id = p_id
  for update;

  if not found then
    raise exception 'Movimentação não encontrada';
  end if;

  if v_movimento.cancelado_em is not null then
    return jsonb_build_object(
      'success', true,
      'already_cancelled', true,
      'id', p_id
    );
  end if;

  update public.movements
  set cancelado_em = now(),
      cancelado_por = v_usuario,
      motivo_cancelamento = 'Cancelado pelo sistema de estoque'
  where id = p_id;

  return jsonb_build_object(
    'success', true,
    'already_cancelled', false,
    'id', p_id,
    'codigo', v_movimento.codigo,
    'tamanho', v_movimento.tamanho,
    'tipo', v_movimento.tipo,
    'qtd', v_movimento.qtd
  );
end;
$$;

revoke all on function public.registrar_movimento(text, bigint, date, text, text, text, integer, numeric, text, text)
  from public, anon;
grant execute on function public.registrar_movimento(text, bigint, date, text, text, text, integer, numeric, text, text)
  to authenticated;

revoke all on function public.cancelar_movimento(text)
  from public, anon;
grant execute on function public.cancelar_movimento(text)
  to authenticated;

revoke all on table public.movements from anon;
revoke insert, update, delete on table public.movements from authenticated;
grant select on table public.movements to authenticated;

revoke all on table public.products from anon;
grant select, insert, update, delete on table public.products to authenticated;

revoke all on table public.stock_balances, public.sales_summary from anon;
grant select on table public.stock_balances, public.sales_summary to authenticated;

drop policy if exists "somente logado - leitura movimentos" on public.movements;
create policy "somente logado - leitura movimentos"
  on public.movements
  for select
  to authenticated
  using (true);

drop policy if exists "somente logado - produtos" on public.products;
create policy "somente logado - produtos"
  on public.products
  for all
  to authenticated
  using (true)
  with check (true);

alter table public.movements replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_rel pr
    join pg_publication p on p.oid = pr.prpubid
    where p.pubname = 'supabase_realtime'
      and pr.prrelid = 'public.movements'::regclass
  ) then
    alter publication supabase_realtime add table public.movements;
  end if;

  if not exists (
    select 1
    from pg_publication_rel pr
    join pg_publication p on p.oid = pr.prpubid
    where p.pubname = 'supabase_realtime'
      and pr.prrelid = 'public.products'::regclass
  ) then
    alter publication supabase_realtime add table public.products;
  end if;
end
$$;

commit;

