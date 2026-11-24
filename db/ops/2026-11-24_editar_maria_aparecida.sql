-- Operação pontual (pedida por Anderson em 24/11/2026): aplicar a mensagem personalizada da
-- Maria Aparecida Rogêdo Campos. O botão "Editar" do Telegram gerou a autorização de edição às 13h39,
-- mas o link do formulário nunca foi configurado (placeholder no WF-ROUTER), então ela ficou sem botão.
-- Aqui: troca a autorização pendente por uma nova gerada dentro da transação (nunca sai do banco) e
-- chama a função oficial save_message_edit, que grava a versão 2 e cria um cartão de aprovação novo.
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;
DO $op$
DECLARE
    v_raw  text := encode(extensions.gen_random_bytes(24), 'hex');
    v_n    integer;
    v_res  record;
BEGIN
    UPDATE rufino_linkedin.connections
       SET active_edit_token_hash = encode(extensions.digest(v_raw, 'sha256'), 'hex')
     WHERE nome = 'Maria Aparecida Rogêdo Campos'
       AND status = 'AGUARDANDO_APROVACAO'
       AND active_edit_token_expires_at > now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN RAISE EXCEPTION 'abortado: esperava 1 contato com edição pendente, achou %', v_n; END IF;

    SELECT * INTO v_res FROM rufino_linkedin.save_message_edit(v_raw,
E'Olá, Maria Aparecida! Tudo bem?\n\nObrigado por ter aceito o meu convite aqui no LinkedIn!\n\nVi que você fundou o Colégio Rogêdo e segue à frente dele há mais de 40 anos. Não é sempre que a gente encontra uma fundadora que continua conduzindo a proposta pedagógica depois de tantas décadas, e o lema "Educação para evoluir e transformar" diz muito sobre essa trajetória.\n\nEstou no segmento educacional há cerca de 15 anos e fiquei com uma curiosidade genuína: o que mantém você motivada depois de mais de 40 anos à frente do colégio?\n\nNão quero tomar seu tempo com uma apresentação comercial. Prefiro começar ouvindo quem construiu uma história assim.\n\nGrande abraço,\nRufino',
        'anderson (via Claude, 24/11)', 'MANUAL-EDITAR-MENSAGEM', NULL);
    RAISE NOTICE 'versao % gravada', v_res.version;
END
$op$;
SELECT c.nome, c.status, mv.version, mv.source, left(mv.message_body, 60) AS inicio,
       (SELECT count(*) FROM rufino_linkedin.notification_jobs n WHERE n.connection_id = c.connection_id AND n.status = 'PENDING') AS cartoes_na_fila
  FROM rufino_linkedin.connections c
  JOIN rufino_linkedin.message_versions mv ON mv.connection_id = c.connection_id
 WHERE c.nome = 'Maria Aparecida Rogêdo Campos'
 ORDER BY mv.version;
COMMIT;
