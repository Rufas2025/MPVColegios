-- Testes de 016_auto_personalized_message.sql (rodar no Postgres local, depois de aplicar a 016).
-- Tudo dentro de uma transação desfeita no fim. Falha = RAISE EXCEPTION.
BEGIN;
DO $t$
DECLARE
    v_a uuid; v_b uuid; v_r record; v_body text; v_n int;
BEGIN
    -- dois contatos sintéticos em AGUARDANDO_D1 com versão 1 do modelo
    SELECT connection_id INTO v_a FROM rufino_linkedin.register_connection(
      p_idempotency_key => 'li-teste-016-a', p_nome => 'Teste A', p_primeiro_nome => 'Teste', p_cargo => 'Diretor',
      p_instituicao => NULL, p_cidade => NULL, p_profile_url => 'https://www.linkedin.com/in/teste-016-a/',
      p_conversation_url => NULL, p_data_conexao => (now() AT TIME ZONE 'America/Sao_Paulo')::date, p_resumo => 'x',
      p_ganchos => '[]'::jsonb, p_melhor_gancho => 'x', p_justificativa => 'x', p_confianca => 0.6, p_sensivel => false,
      p_alertas => '[]'::jsonb, p_brain_version => 't', p_mensagem => 'Olá, modelo', p_workflow_name => 'TESTE',
      p_execution_id => '1', p_data_conexao_origem => 'linkedin_email_notificacao_aceite',
      p_data_conexao_confirmado_por => 'sistema:email-linkedin');
    SELECT connection_id INTO v_b FROM rufino_linkedin.register_connection(
      p_idempotency_key => 'li-teste-016-b', p_nome => 'Teste B', p_primeiro_nome => 'Teste', p_cargo => 'Diretor',
      p_instituicao => NULL, p_cidade => NULL, p_profile_url => 'https://www.linkedin.com/in/teste-016-b/',
      p_conversation_url => NULL, p_data_conexao => (now() AT TIME ZONE 'America/Sao_Paulo')::date, p_resumo => 'x',
      p_ganchos => '[]'::jsonb, p_melhor_gancho => 'x', p_justificativa => 'x', p_confianca => 0.6, p_sensivel => false,
      p_alertas => '[]'::jsonb, p_brain_version => 't', p_mensagem => 'Olá, modelo', p_workflow_name => 'TESTE',
      p_execution_id => '1', p_data_conexao_origem => 'linkedin_email_notificacao_aceite',
      p_data_conexao_confirmado_por => 'sistema:email-linkedin');

    -- 1) grava a versão 2 em AGUARDANDO_D1
    SELECT * INTO v_r FROM rufino_linkedin.save_auto_message(v_a, 'Olá, personalizada', 'auto-pesquisa:teste');
    IF NOT v_r.applied OR v_r.version <> 2 THEN RAISE EXCEPTION 'T1 falhou: %', v_r.reason; END IF;

    -- 2) segunda chamada não sobrescreve (idempotente)
    SELECT * INTO v_r FROM rufino_linkedin.save_auto_message(v_a, 'Olá, outra', 'auto-pesquisa:teste');
    IF v_r.applied THEN RAISE EXCEPTION 'T2 falhou: sobrescreveu'; END IF;
    SELECT count(*) INTO v_n FROM rufino_linkedin.message_versions WHERE connection_id = v_a;
    IF v_n <> 2 THEN RAISE EXCEPTION 'T2 falhou: % versoes', v_n; END IF;

    -- 3) texto vazio é recusado
    BEGIN
        PERFORM rufino_linkedin.save_auto_message(v_b, '   ', 'auto-pesquisa:teste');
        RAISE EXCEPTION 'T3 falhou: aceitou vazio';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'T3%' THEN RAISE; END IF;
    END;

    -- 4) o claim das 9h entrega a versão personalizada
    UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute' WHERE connection_id IN (v_a, v_b);
    SELECT message_body INTO v_body FROM rufino_linkedin.claim_due_connections(p_limit => 100) WHERE connection_id = v_a;
    IF v_body IS DISTINCT FROM 'Olá, personalizada' THEN RAISE EXCEPTION 'T4 falhou: claim entregou %', v_body; END IF;

    -- 5) depois do claim (AGUARDANDO_APROVACAO) a função não mexe mais
    SELECT * INTO v_r FROM rufino_linkedin.save_auto_message(v_b, 'Olá, tarde demais', 'auto-pesquisa:teste');
    IF v_r.applied THEN RAISE EXCEPTION 'T5 falhou: gravou fora de AGUARDANDO_D1'; END IF;

    -- 6) contato inexistente devolve applied = false
    SELECT * INTO v_r FROM rufino_linkedin.save_auto_message(gen_random_uuid(), 'x', 'auto-pesquisa:teste');
    IF v_r.applied THEN RAISE EXCEPTION 'T6 falhou'; END IF;

    -- 7) permissões: app executa, PUBLIC não
    IF NOT has_function_privilege('n8n_rufino_linkedin_dev', 'rufino_linkedin.save_auto_message(uuid,text,text,text,text)', 'EXECUTE')
       THEN RAISE EXCEPTION 'T7 falhou: app sem EXECUTE'; END IF;
    IF has_function_privilege('public', 'rufino_linkedin.save_auto_message(uuid,text,text,text,text)', 'EXECUTE')
       THEN RAISE EXCEPTION 'T7 falhou: PUBLIC com EXECUTE'; END IF;

    RAISE NOTICE 'auto_personalized_message: 7 testes ok';
END
$t$;
ROLLBACK;
