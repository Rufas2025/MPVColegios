-- Operação pontual (pedida por Anderson em 25/11/2026: "já vamos atualizar a mensagem e me manda no Telegram").
-- Troca a mensagem D+1 de três contatos pela versão personalizada (lida na Experiência do perfil, prints enviados
-- pelo Anderson) usando a função oficial save_message_edit, que grava a versão 2 e cria um cartão de aprovação novo.
-- Travas: cada contato precisa estar em AGUARDANDO_APROVACAO e só com a versão 1; qualquer falha desfaz tudo.
-- O token de aprovação antigo é consumido aqui (o mesmo que issue_action_token faria ao emitir o novo), para o
-- cartão antigo do Telegram parar de funcionar na hora.
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;
DO $op$
DECLARE
    r      record;
    v_id   uuid;
    v_ver  integer;
    v_raw  text;
    v_n    integer;
    v_res  record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('https://www.linkedin.com/in/daniela-d-b455004b', $m$Olá, Daniela! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você chegou ao Colégio Ética este ano, depois de quase 13 anos no Johann Gauss, onde começou como professora de alfabetização. Colégio novo, cidade nova, cultura nova: imagino que 2026 tenha sido um ano e tanto. Rsrs

Espero que tenha sido um ano de muitas conquistas. Como foi esse primeiro ano para você?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/isabela-rosenberg-90b548111', $m$Olá, Isabela! Tudo bem?

Obrigado por ter aceito o meu convite aqui no LinkedIn!

Vi que você está na direção de unidade da Rede Decisão há pouco mais de um ano, depois de quase quatro anos na coordenação bilíngue do Bernoulli. Sair do Bernoulli, que nasceu aí em BH, para a Decisão, que vem de São Paulo, deve ter sido uma bela mudança de cultura. Rsrs

Inclusive, conheço o Betinho e já tivemos algumas boas conversas.

Desejo muito sucesso nessa fase, e vai ser um prazer trocar umas ideias com você mais para frente. Como tem sido essa adaptação para você?

Grande abraço,
Rufino$m$),
        ('https://www.linkedin.com/in/james-pinheiro-dos-santos', $m$Fala, James! Tudo bem?

Valeu por ter aceito o meu convite aqui no LinkedIn!

Vi que você está há mais de três anos na direção de ensino da Fundação Bradesco em Itajubá, depois de dirigir o Marista Champagnat em Brasília. Baita trajetória!

A Fundação Bradesco é um projeto que eu admiro muito. Sou de São Paulo e já estive na Cidade de Deus, uma estrutura espetacular. Como entrar por São Paulo é bem desafiador, resolvi tentar por Minas. Será que por aí eu tenho mais sorte, James? Rsrs

Brincadeiras à parte, vai ser um prazer te conhecer melhor. Como tem sido liderar a unidade de Itajubá?

Grande abraço,
Rufino$m$)
    ) AS t(url, msg)
    LOOP
        SELECT c.connection_id INTO v_id
          FROM rufino_linkedin.connections c
         WHERE lower(rtrim(c.profile_url, '/')) = r.url
           AND c.status = 'AGUARDANDO_APROVACAO';
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n <> 1 THEN RAISE EXCEPTION 'abortado: % esperado 1 contato aguardando aprovacao, achou %', r.url, v_n; END IF;

        SELECT max(mv.version) INTO v_ver FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_id;
        IF v_ver <> 1 THEN RAISE EXCEPTION 'abortado: % ja tem versao % (editado pelo Telegram?)', r.url, v_ver; END IF;

        UPDATE rufino_linkedin.action_tokens
           SET consumed_at = now()
         WHERE connection_id = v_id AND scope = 'APPROVAL' AND consumed_at IS NULL;

        v_raw := encode(extensions.gen_random_bytes(24), 'hex');
        UPDATE rufino_linkedin.connections
           SET active_edit_token_hash = encode(extensions.digest(v_raw, 'sha256'), 'hex'),
               active_edit_token_expires_at = now() + interval '10 minutes'
         WHERE connection_id = v_id;

        SELECT * INTO v_res FROM rufino_linkedin.save_message_edit(v_raw, r.msg,
            'anderson (via Claude, 25/11)', 'MANUAL-EDITAR-MENSAGEM', NULL);
        RAISE NOTICE '% versao % gravada', r.url, v_res.version;
    END LOOP;
END
$op$;
SELECT c.nome, c.status, mv.version, mv.source, left(mv.message_body, 50) AS inicio,
       (SELECT count(*) FROM rufino_linkedin.notification_jobs n WHERE n.connection_id = c.connection_id AND n.status = 'PENDING') AS cartoes_na_fila,
       (SELECT count(*) FROM rufino_linkedin.action_tokens t WHERE t.connection_id = c.connection_id AND t.consumed_at IS NULL) AS tokens_abertos
  FROM rufino_linkedin.connections c
  JOIN rufino_linkedin.message_versions mv ON mv.connection_id = c.connection_id
 WHERE lower(rtrim(c.profile_url, '/')) IN ('https://www.linkedin.com/in/daniela-d-b455004b',
                                            'https://www.linkedin.com/in/isabela-rosenberg-90b548111',
                                            'https://www.linkedin.com/in/james-pinheiro-dos-santos')
 ORDER BY c.nome, mv.version;
COMMIT;
