-- Testes de 017_register_reply.sql (rodar no Postgres local, depois de aplicar a 017).
-- Tudo dentro de uma transação desfeita no fim. Falha = RAISE EXCEPTION.
BEGIN;
DO $t$
DECLARE
    v_ana uuid; v_anabela uuid; v_angela uuid; v_d1 uuid; v_r record; v_n int; v_s text;
    v_nomes text[] := ARRAY['Teste Resp Ana', 'Teste Resp Anabela', 'Teste Resp Ângela', 'Teste Resp Dório'];
    v_ids uuid[] := ARRAY[]::uuid[];
    v_id uuid; i int; v_passo text[];
BEGIN
    FOR i IN 1..4 LOOP
        SELECT connection_id INTO v_id FROM rufino_linkedin.register_connection(
          p_idempotency_key => 'li-teste-017-' || i, p_nome => v_nomes[i], p_primeiro_nome => split_part(v_nomes[i], ' ', 3),
          p_cargo => 'Diretora', p_instituicao => NULL, p_cidade => NULL,
          p_profile_url => 'https://www.linkedin.com/in/teste-017-' || i || '/', p_conversation_url => NULL,
          p_data_conexao => (now() AT TIME ZONE 'America/Sao_Paulo')::date, p_resumo => 'x', p_ganchos => '[]'::jsonb,
          p_melhor_gancho => 'x', p_justificativa => 'x', p_confianca => 0.6, p_sensivel => false, p_alertas => '[]'::jsonb,
          p_brain_version => 't', p_mensagem => 'Olá, modelo', p_workflow_name => 'TESTE', p_execution_id => '1',
          p_data_conexao_origem => 'linkedin_email_notificacao_aceite', p_data_conexao_confirmado_por => 'sistema:email-linkedin');
        v_ids := v_ids || v_id;
    END LOOP;
    v_ana := v_ids[1]; v_anabela := v_ids[2]; v_angela := v_ids[3]; v_d1 := v_ids[4];

    -- Ana, Anabela e Ângela chegam a FOLLOWUP_PENDENTE (mensagem enviada); Dório fica em AGUARDANDO_D1.
    v_passo := ARRAY['AGUARDANDO_D1','AGUARDANDO_APROVACAO','APROVADO','PRONTO_PARA_ENVIO','ENVIADO','FOLLOWUP_PENDENTE'];
    FOREACH v_id IN ARRAY ARRAY[v_ana, v_anabela, v_angela] LOOP
        FOR i IN 1..5 LOOP
            PERFORM rufino_linkedin.transition_connection_status(v_id, v_passo[i], v_passo[i+1], 'teste', 'teste', 'TESTE');
        END LOOP;
        INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for) VALUES (v_id, 1, now() + interval '3 days');
    END LOOP;

    -- 1) busca curta
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('an');
    IF v_r.applied OR v_r.reason NOT LIKE 'busca%' THEN RAISE EXCEPTION 'T1 falhou: %', v_r.reason; END IF;

    -- 2) ambíguo: nada é gravado e os nomes voltam
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('teste resp an');
    IF v_r.applied OR v_r.candidatos NOT LIKE '%Ana%Anabela%' THEN RAISE EXCEPTION 'T2 falhou: % / %', v_r.reason, v_r.candidatos; END IF;
    SELECT count(*) INTO v_n FROM rufino_linkedin.connections WHERE connection_id IN (v_ana, v_anabela) AND status = 'FOLLOWUP_PENDENTE';
    IF v_n <> 2 THEN RAISE EXCEPTION 'T2 falhou: gravou algo'; END IF;

    -- 3) nome exato desempata (Ana, não Anabela); maiúsculas e espaços não importam
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('  TESTE   resp ana ');
    IF NOT v_r.applied OR v_r.connection_id <> v_ana THEN RAISE EXCEPTION 'T3 falhou: % %', v_r.reason, v_r.nome; END IF;
    SELECT status INTO v_s FROM rufino_linkedin.connections WHERE connection_id = v_ana;
    IF v_s <> 'ENCERRADO' THEN RAISE EXCEPTION 'T3 falhou: status %', v_s; END IF;
    SELECT count(*) INTO v_n FROM rufino_linkedin.connection_status_history WHERE connection_id = v_ana AND new_status = 'RESPONDEU';
    IF v_n <> 1 THEN RAISE EXCEPTION 'T3 falhou: historico RESPONDEU = %', v_n; END IF;
    SELECT count(*) INTO v_n FROM rufino_linkedin.followups WHERE connection_id = v_ana AND resultado = 'RESPONDEU' AND executed_at IS NOT NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'T3 falhou: followup nao fechado'; END IF;
    SELECT status INTO v_s FROM rufino_linkedin.connections WHERE connection_id = v_anabela;
    IF v_s <> 'FOLLOWUP_PENDENTE' THEN RAISE EXCEPTION 'T3 falhou: mexeu na Anabela'; END IF;

    -- 4) segunda vez com o mesmo nome: não registra de novo e não cai na Anabela
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('teste resp ana');
    IF v_r.applied OR v_r.reason <> 'nenhum desses aguarda resposta' THEN RAISE EXCEPTION 'T4 falhou: % %', v_r.reason, v_r.nome; END IF;
    SELECT status INTO v_s FROM rufino_linkedin.connections WHERE connection_id = v_anabela;
    IF v_s <> 'FOLLOWUP_PENDENTE' THEN RAISE EXCEPTION 'T4 falhou: registrou a Anabela'; END IF;

    -- 5) sem acento acha com acento
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('resp angela');
    IF NOT v_r.applied OR v_r.connection_id <> v_angela THEN RAISE EXCEPTION 'T5 falhou: %', v_r.reason; END IF;

    -- 6) contato que ainda não recebeu mensagem
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('resp dorio');
    IF v_r.applied OR v_r.reason <> 'nenhum desses aguarda resposta' OR v_r.candidatos NOT LIKE '%AGUARDANDO_D1%' THEN
        RAISE EXCEPTION 'T6 falhou: % %', v_r.reason, v_r.candidatos; END IF;

    -- 7) nome que não existe
    SELECT * INTO v_r FROM rufino_linkedin.register_reply('fulano inexistente 017');
    IF v_r.applied OR v_r.reason <> 'nenhum contato com esse nome' THEN RAISE EXCEPTION 'T7 falhou'; END IF;

    -- 8) permissões: app executa, PUBLIC não
    IF NOT has_function_privilege('n8n_rufino_linkedin_dev', 'rufino_linkedin.register_reply(text,text,text,text)', 'EXECUTE')
       THEN RAISE EXCEPTION 'T8 falhou: app sem EXECUTE'; END IF;
    IF has_function_privilege('public', 'rufino_linkedin.register_reply(text,text,text,text)', 'EXECUTE')
       THEN RAISE EXCEPTION 'T8 falhou: PUBLIC com EXECUTE'; END IF;

    RAISE NOTICE 'register_reply: 8 testes ok';
END
$t$;
ROLLBACK;
