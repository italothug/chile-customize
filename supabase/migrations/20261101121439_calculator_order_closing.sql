create or replace function public.fechar_pedido_calculadora(p_pedido_id text,p_cliente text,p_pagamento numeric,p_itens jsonb)
returns jsonb language plpgsql security invoker set search_path=''
as $$
declare v_item jsonb;v_i integer:=0;v_id text;v_result jsonb;v_cliente text:=btrim(coalesce(p_cliente,''));v_codigo text;v_tamanho text;v_qtd integer;v_valor numeric;
begin
 if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
 if p_pedido_id is null or btrim(p_pedido_id)='' or length(p_pedido_id)>80 then raise exception 'Identificador do pedido inválido'; end if;
 if v_cliente='' or length(v_cliente)>120 then raise exception 'Informe o nome do cliente (até 120 caracteres)'; end if;
 if p_pagamento not in (0,50,100) then raise exception 'Selecione pagamento de 0%%, 50%% ou 100%%'; end if;
 if p_itens is null or jsonb_typeof(p_itens)<>'array' or jsonb_array_length(p_itens) not between 1 and 50 then raise exception 'O pedido deve conter de 1 a 50 itens'; end if;
 for v_item in select value from jsonb_array_elements(p_itens) as t(value) loop
   v_i:=v_i+1;
   v_codigo:=nullif(btrim(v_item->>'codigo'),'');
   v_tamanho:=nullif(btrim(v_item->>'tamanho'),'');
   v_qtd:=(v_item->>'qtd')::integer;
   v_valor:=(v_item->>'valor')::numeric;
   if v_codigo is null or v_tamanho is null or v_qtd<=0 or v_valor<0 then raise exception 'Item % inválido',v_i; end if;
   v_id:=p_pedido_id||':'||v_i;
   select public.registrar_movimento(v_id,(extract(epoch from clock_timestamp())*1000)::bigint,current_date,v_codigo,v_tamanho,'Saída',v_qtd,v_valor,'Pedido: '||v_cliente,'Fechado na calculadora DTF',p_pagamento) into v_result;
 end loop;
 return jsonb_build_object('success',true,'pedido_id',p_pedido_id,'itens',v_i);
end $$;
revoke execute on function public.fechar_pedido_calculadora(text,text,numeric,jsonb) from public,anon;
grant execute on function public.fechar_pedido_calculadora(text,text,numeric,jsonb) to authenticated;