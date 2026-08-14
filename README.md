# Estoque Chile — Vercel

Projeto web de controle de estoque preparado para publicação no Vercel.

## Estrutura

- `public/index.html` — aplicação atual.
- `package.json` — configuração mínima do projeto.
- `vercel.json` — configuração de publicação.
- `.gitignore` — arquivos que não devem ir para o GitHub.

## Publicação no GitHub

1. Crie um repositório no GitHub.
2. Envie todos os arquivos desta pasta para o repositório.
3. No Vercel, importe o repositório.
4. Não é necessário configurar um build command.
5. O diretório de saída pode ser `public`.
6. Publique.

## Dados e auditoria

O sistema usa Supabase com autenticação, RLS, movimentações via RPC e sincronização Realtime. Movimentações não são apagadas: cancelamentos registram data, usuário e motivo. Produtos são arquivados/reativados para preservar o histórico.

As migrations formais ficam em `supabase/migrations`. Nunca coloque uma chave `service_role` no frontend.

