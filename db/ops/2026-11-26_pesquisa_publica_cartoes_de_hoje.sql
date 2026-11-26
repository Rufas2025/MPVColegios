-- Operação pontual (26/11/2026, dentro da autorização de 25/11 de Anderson para atualizar as mensagens com a pesquisa).
-- Troca a mensagem D+1 dos 3 cartões de hoje (Cássia, Marcelo, Luciana Gomes) pela versão personalizada com a pesquisa
-- pública (escola atual e trajetória com fonte). Mesma mecânica e travas: save_message_edit, token antigo consumido,
-- quem não está em AGUARDANDO_APROVACAO ou já tem versão editada é PULADO. Casa por nome (único na fila de hoje).
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
        ('Cássia Vanessa Nova', $m$Olá, Cássia! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você está na direção pedagógica do Fundamental II do Colégio Chaminade, em Bauru. Depois de 15 anos no segmento educacional, sei que do 6º ao 9º ano é uma fase e tanto, e cada escola encontra o seu jeito de conduzir.

Cássia, o que tem funcionado aí no Fundamental II do Chaminade para manter os alunos engajados?

Grande abraço,
Rufino$m$),
        ('Marcelo Piantkoski', $m$Fala, Marcelo! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que a sua trajetória passa pela direção de colégios La Salle, em São Carlos e em Niterói, e do Colégio Cenecista José Ferreira, em Uberaba. Baita caminhada, e por escolas com culturas bem diferentes!

Marcelo, depois de dirigir tantas escolas, o que você sempre leva de uma para a outra?

Grande abraço,
Rufino$m$),
        ('Luciana Gomes', $m$Olá, Luciana! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você está à frente do Fundamental I do Colégio Visconde de Porto Seguro e que comentou a Semana das Crianças da escola. Bonito ver o cuidado com essa fase!

Luciana, o que tem funcionado aí no Fundamental I do Porto Seguro para manter as crianças engajadas?

Grande abraço,
Rufino$m$)
    ) AS t(url, msg)
    LOOP
        SELECT c.connection_id, c.status INTO v_id, v_st
          FROM rufino_linkedin.connections c
         WHERE c.nome = r.url AND c.status IN ('AGUARDANDO_APROVACAO','AGUARDANDO_D1','PRONTO_PARA_ENVIO','ENVIADO');
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
            'anderson (via Claude, pesquisa publica, 26/11)', 'MANUAL-PESQUISA-PUBLICA', NULL);
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
 WHERE c.nome IN ('Cássia Vanessa Nova','Marcelo Piantkoski','Luciana Gomes')
 ORDER BY c.nome;
COMMIT;
