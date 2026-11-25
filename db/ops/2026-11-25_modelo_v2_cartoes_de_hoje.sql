-- Operação pontual (autorizada por Anderson em 25/11/2026: "autorizo"). Troca a mensagem D+1 dos 10 cartões de
-- aprovação de hoje pelo modelo v2 (tom de escuta, pergunta pelo perfil do cargo), gerado pela mesma função publicada no
-- WF-01E (versão a572dc1f). Usa a função oficial save_message_edit (versão 2 + cartão novo) e consome o token de aprovação
-- antigo (o cartão antigo para de funcionar). Contato que não está mais em AGUARDANDO_APROVACAO ou já tem versão editada
-- é PULADO (aviso), não sobrescrito.
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;
DO $op$
DECLARE
    r      record;
    v_id   uuid;
    v_st   text;
    v_ver  integer;
    v_raw  text;
    v_res  record;
    v_ok   integer := 0;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('https://www.linkedin.com/in/adriana-monteiro-67ab47339', $m$Olá, Adriana! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Adriana, o que tem funcionado aí para equilibrar o pedagógico com os números da escola?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/karlla-rodrigues-29399b363', $m$Olá, Karlla! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Karlla, o que tem funcionado aí para manter os alunos engajados?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/leonardo-matos-27637869', $m$Fala, Leonardo! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Leonardo, o que tem funcionado aí para manter os alunos engajados?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/lisamar-delazeri-a6b401a2', $m$Olá, Lisamar! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Lisamar, o que tem funcionado aí para equilibrar o pedagógico com os números da escola?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/luiz-antonio-lim%c3%a3o-110132230', $m$Fala, Luiz! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que você está à frente do Colégio Sapiens. Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Luiz, o que tem funcionado aí no Colégio Sapiens para manter os alunos engajados?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/mauro-longato', $m$Fala, Mauro! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Mauro, o que tem funcionado aí para manter a captação e a rematrícula em alta?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/paulo-abreu-52279021', $m$Fala, Paulo! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que você está à frente da Maple Bear Gavea. Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Paulo, o que tem funcionado aí na Maple Bear Gavea para equilibrar o pedagógico com os números da escola?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/ricardo-fargnoli-56b0b528', $m$Fala, Ricardo! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Ricardo, o que tem funcionado aí para equilibrar o pedagógico com os números da escola?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/roberta-dias-a5178b194', $m$Olá, Roberta! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você está à frente do Colégio Dr. Walter Belian. Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Roberta, o que tem funcionado aí no Colégio Dr. Walter Belian para equilibrar o pedagógico com os números da escola?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/thais-almeida-0548345b', $m$Olá, Thais! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Depois de 15 anos no segmento educacional, percebo o quanto a educação mudou, e cada escola tem a sua história. Conversar com quem está na liderança é o que mais me ensina.

Thais, o que tem funcionado aí para manter os alunos engajados?

Grande abraço,
Rufino$m$)
    ) AS t(url, msg)
    LOOP
        SELECT c.connection_id, c.status INTO v_id, v_st
          FROM rufino_linkedin.connections c
         WHERE lower(rtrim(c.profile_url, '/')) = r.url;
        IF v_id IS NULL THEN RAISE NOTICE 'PULADO % (nao encontrado)', r.url; CONTINUE; END IF;
        IF v_st <> 'AGUARDANDO_APROVACAO' THEN RAISE NOTICE 'PULADO % (status %)', r.url, v_st; CONTINUE; END IF;
        SELECT max(mv.version) INTO v_ver FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_id;
        IF v_ver <> 1 THEN RAISE NOTICE 'PULADO % (ja tem versao %)', r.url, v_ver; CONTINUE; END IF;

        UPDATE rufino_linkedin.action_tokens
           SET consumed_at = now()
         WHERE connection_id = v_id AND scope = 'APPROVAL' AND consumed_at IS NULL;

        v_raw := encode(extensions.gen_random_bytes(24), 'hex');
        UPDATE rufino_linkedin.connections
           SET active_edit_token_hash = encode(extensions.digest(v_raw, 'sha256'), 'hex'),
               active_edit_token_expires_at = now() + interval '10 minutes'
         WHERE connection_id = v_id;

        SELECT * INTO v_res FROM rufino_linkedin.save_message_edit(v_raw, r.msg,
            'modelo v2 (via Claude, 25/11)', 'MANUAL-MODELO-V2', NULL);
        v_ok := v_ok + 1;
        v_id := NULL;
    END LOOP;
    RAISE NOTICE '% contatos atualizados', v_ok;
END
$op$;
SELECT c.nome, c.status, mv.version, mv.source,
       (SELECT count(*) FROM rufino_linkedin.notification_jobs n WHERE n.connection_id = c.connection_id AND n.status = 'PENDING') AS cartoes_na_fila
  FROM rufino_linkedin.connections c
  JOIN LATERAL (SELECT m.version, m.source FROM rufino_linkedin.message_versions m WHERE m.connection_id = c.connection_id ORDER BY m.version DESC LIMIT 1) mv ON true
 WHERE lower(rtrim(c.profile_url, '/')) IN ('https://www.linkedin.com/in/adriana-monteiro-67ab47339',
         'https://www.linkedin.com/in/karlla-rodrigues-29399b363',
         'https://www.linkedin.com/in/leonardo-matos-27637869',
         'https://www.linkedin.com/in/lisamar-delazeri-a6b401a2',
         'https://www.linkedin.com/in/luiz-antonio-lim%c3%a3o-110132230',
         'https://www.linkedin.com/in/mauro-longato',
         'https://www.linkedin.com/in/paulo-abreu-52279021',
         'https://www.linkedin.com/in/ricardo-fargnoli-56b0b528',
         'https://www.linkedin.com/in/roberta-dias-a5178b194',
         'https://www.linkedin.com/in/thais-almeida-0548345b')
 ORDER BY c.nome;
COMMIT;
