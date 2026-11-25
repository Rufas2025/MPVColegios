-- Operação pontual (autorizada por Anderson em 25/11/2026: "já deixo o meu autorizado"). Troca a mensagem D+1 de 5
-- contatos esperando aprovação pela versão personalizada com a pesquisa pública (escola atual, tempo de casa e gancho,
-- todos com fonte). Mesma mecânica e travas de 2026-11-25_modelo_v2_cartoes_de_hoje.sql: save_message_edit, token antigo
-- consumido, quem não está em AGUARDANDO_APROVACAO ou já tem versão editada é PULADO.
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
        ('https://www.linkedin.com/in/fabio-alves-18301999', $m$Fala, Fabio! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que são mais de 31 anos de dedicação ao Alfa CEM e que, neste ano, a rede trouxe o Instituto Maia Vinagre, uma escola com 72 anos de história em Niterói. Parabéns pela jornada e pelo passo!

Fabio, como tem sido integrar uma escola com tanta história à Rede Alfa CEM?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/narda-helena-jorosky-034411217', $m$Olá, Narda! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você está na direção pedagógica do Colégio Santo Antônio, que esteve no Bernoulli Reload 2025 e premiou os alunos da Olimpíada Mirim da OBMEP no teatro do colégio. Bonito ver a escola celebrando os alunos assim!

Narda, o que tem funcionado aí no CSA para manter os alunos engajados?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/fernando-tiago-kotz-9b32b9175', $m$Fala, Fernando! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi seu nome entre os palestrantes da Educa Week 2026: são 17 anos na educação e, desde 2025, a superintendência executiva da Sagrado Rede de Educação. É uma bela mudança de cadeira!

Fernando, o que mais mudou no seu olhar sobre a escola depois que você passou a cuidar de uma rede inteira?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/ari-de-sa-neto-3a696222', $m$Fala, Ari! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que a Arco Educação começou como uma única escola no Nordeste e que você está entre os finalistas do EY World Entrepreneur Of The Year 2026 pelo Brasil. Parabéns! É uma trajetória que inspira quem vive o segmento educacional.

Ari, olhando para trás, o que daquela primeira escola continua vivo na Arco de hoje?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/m%c3%a1rcio-willyans-ribeiro-63a192185', $m$Fala, Márcio! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que você está na direção do Colégio Bernoulli Vale do Sereno desde 2024, depois de passar pela sala de aula, em escolas públicas e privadas, pela coordenação pedagógica na Positivo e por um doutorado em Educação. Baita trajetória!

Márcio, o que da sala de aula você mais leva para a direção hoje?

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
            'anderson (via Claude, pesquisa publica, 25/11)', 'MANUAL-PESQUISA-PUBLICA', NULL);
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
 WHERE lower(rtrim(c.profile_url, '/')) IN ('https://www.linkedin.com/in/fabio-alves-18301999',
         'https://www.linkedin.com/in/narda-helena-jorosky-034411217',
         'https://www.linkedin.com/in/fernando-tiago-kotz-9b32b9175',
         'https://www.linkedin.com/in/ari-de-sa-neto-3a696222',
         'https://www.linkedin.com/in/m%c3%a1rcio-willyans-ribeiro-63a192185')
 ORDER BY c.nome;
COMMIT;
