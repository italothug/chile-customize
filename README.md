# #UseChile — Estoque

Projeto web de controle de estoque preparado para publicação no Vercel.

## Estrutura

- `index.html` — aplicação estática e frontend atual, na raiz do repositório.
- `package.json` — configuração mínima do projeto.
- `vercel.json` — configuração de publicação e headers de segurança.
- `supabase/migrations/` — migrations formais aplicadas ao Supabase.
- `database/upgrade_inventory.sql` — documentação SQL da atualização inicial do estoque.

## Publicação no GitHub

1. Envie as alterações para o repositório GitHub conectado ao Vercel.
2. O Vercel publica o `index.html` diretamente da raiz do repositório.
3. Não configure build command nem output directory: este projeto é estático e não possui etapa de build.
4. Confirme que o deployment associado ao commit terminou com status `success`.

## Dados e auditoria

O sistema usa Supabase com autenticação, RLS, movimentações via RPC e sincronização Realtime. Movimentações não são apagadas: cancelamentos registram data, usuário e motivo. Produtos são arquivados/reativados para preservar o histórico. A área de vendas agrupa os lançamentos por mês e acompanha pagamentos de 50% ou 100% sem alterar o valor original da venda.

As migrations formais ficam em `supabase/migrations`. Nunca coloque uma chave `service_role` no frontend.

