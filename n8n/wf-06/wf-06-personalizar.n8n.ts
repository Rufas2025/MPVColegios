import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

// WF-06: mensagem D+1 personalizada com a pesquisa pública (fase 2, autorizada por Anderson em 26/11/2026).
// Dias úteis 8h30 (antes do WF-02 das 9h). Gerado por n8n/wf-06/montar-wf.js: editar os arquivos-fonte, não este.

const agenda = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Dias úteis 8h30', parameters: { rule: { interval: [{ field: 'cronExpression', expression: '0 30 8 * * 1-5' }] } } }
});

const contatos = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Contatos do Dia',
    parameters: { operation: 'executeQuery', query: "-- Contatos que viram cartão às 9h de hoje, ainda com a versão 1 do modelo e com pesquisa útil (alta ou média).\nSELECT c.connection_id::text AS connection_id, c.nome, c.primeiro_nome, c.cargo, c.instituicao,\n       COALESCE((SELECT a.resumo FROM rufino_linkedin.analyses a WHERE a.connection_id = c.connection_id\n                  ORDER BY a.created_at DESC LIMIT 1), c.cargo, '') AS titulo,\n       mv.message_body AS mensagem_modelo,\n       r.confianca, r.trajetoria, r.tempo_de_casa, r.rapport, r.bloco_cartao\n  FROM rufino_linkedin.connections c\n  JOIN LATERAL (SELECT m.version, m.source, m.edited_by, m.message_body FROM rufino_linkedin.message_versions m\n                 WHERE m.connection_id = c.connection_id ORDER BY m.version DESC LIMIT 1) mv ON true\n  JOIN LATERAL rufino_linkedin.get_contact_research(c.connection_id, 90) r ON true\n WHERE c.status = 'AGUARDANDO_D1'\n   AND c.scheduled_at <= ((now() AT TIME ZONE 'America/Sao_Paulo')::date + time '09:05') AT TIME ZONE 'America/Sao_Paulo'\n   AND mv.version = 1 AND mv.source = 'gpt' AND mv.edited_by IS NULL\n   AND r.confianca IN ('alta', 'media')\n ORDER BY c.scheduled_at, c.nome\n LIMIT 60;", options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

const montar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Montar Pedido', parameters: { mode: 'runOnceForAllItems', jsCode: "// Monta o pedido à API do Claude para cada contato (WF-06, fase 2, 26/11/2026).\nconst SISTEMA = \"Você escreve, em nome de Anderson Rufino (assina \\\"Rufino\\\"), a primeira mensagem no LinkedIn para quem lidera uma escola particular e acabou de aceitar o convite dele. Rufino está há 15 anos no segmento educacional e conversa com lideranças de escolas pelo Brasil. O tom é de humildade, escuta e respeito: ele nunca ensina a escola, nunca vende, nunca pede reunião. A mensagem existe para abrir uma conversa.\\n\\nVocê recebe: os dados do contato, a pesquisa pública sobre a pessoa (com fatos já conferidos) e a mensagem_modelo, que é a versão padrão já aprovada.\\n\\nFormato da mensagem (blocos separados por uma linha em branco):\\n1. As duas primeiras linhas da mensagem_modelo, sem mudar nada (saudação e agradecimento; o gênero já está certo).\\n2. Um parágrafo de gancho, com 1 ou 2 fatos da pesquisa: a escola atual pelo nome; o tempo de casa só se estiver na pesquisa; de onde a pessoa veio (trajetória) ou um momento da escola (programa novo, evento, prêmio, aquisição). Pode parabenizar. Pode mencionar os 15 anos do Rufino como percepção, nunca como currículo.\\n3. Uma única pergunta, fácil de responder, ligada ao gancho e à experiência da pessoa. Ela começa com o primeiro nome. Exemplos: \\\"como tem sido essa adaptação?\\\", \\\"o que tem funcionado aí no Colégio X para manter os alunos engajados?\\\", \\\"como tem sido a recepção das famílias ao programa?\\\".\\n4. As duas últimas linhas exatamente: \\\"Grande abraço,\\\" e \\\"Rufino\\\".\\n\\nRegras:\\n- Só use fatos que estão na pesquisa ou na mensagem_modelo. Nunca invente nome, número, data, cargo, escola, evento ou relação pessoal.\\n- Se a pesquisa parecer de outra pessoa ou contradizer o título do perfil (outra escola, outro cargo, rede pública, secretaria de educação, ensino superior), responda usar = false e explique em motivo.\\n- Se a pesquisa não trouxer nenhum fato útil além do que já está na mensagem_modelo, responda usar = false.\\n- Não cite fontes nem sites (\\\"vi no LinkedIn\\\", \\\"segundo o site\\\"). Use \\\"Vi que...\\\".\\n- Sem travessão, sem \\\"nos conectamos\\\", sem emoji, sem negrito, sem aspas, sem palavras como transformar, inovador, potencializar, jornada de excelência. \\\"Rsrs\\\" no máximo uma vez, só se couber naturalmente.\\n- Uma pergunta só. No máximo 95 palavras no total. Português do Brasil, tom de conversa.\\n\\nExemplos aprovados pelo Anderson (o gancho muda conforme a pesquisa):\\n\\nFala, Leonardo! Tudo bem?\\n\\nValeu por ter aceito o meu convite aqui no LinkedIn!\\n\\nVi que você está na direção pedagógica do Colégio CCPA desde 2024, depois de passar pela coordenação geral pedagógica da escola. E agora o CCPA lança o programa de High School com diploma duplo a partir de 2026. Parabéns pela trajetória e pela iniciativa!\\n\\nLeonardo, como tem sido a recepção das famílias ao programa?\\n\\nGrande abraço,\\nRufino\\n\\n---\\n\\nOlá, Daniela! Tudo bem?\\n\\nObrigado por ter aceito o meu convite aqui no LinkedIn!\\n\\nVi que você chegou ao Colégio Ética este ano, depois de quase 13 anos no Johann Gauss, onde começou como professora de alfabetização. Colégio novo, cidade nova, cultura nova: imagino que 2026 tenha sido um ano e tanto. Rsrs\\n\\nEspero que tenha sido um ano de muitas conquistas. Como foi esse primeiro ano para você?\\n\\nGrande abraço,\\nRufino\\n\\n---\\n\\nFala, Fernando! Tudo bem?\\n\\nValeu por ter aceito o meu convite aqui no LinkedIn!\\n\\nVi seu nome entre os palestrantes da Educa Week 2026: são 17 anos na educação e, desde 2025, a superintendência executiva da Sagrado Rede de Educação. É uma bela mudança de cadeira!\\n\\nFernando, o que mais mudou no seu olhar sobre a escola depois que você passou a cuidar de uma rede inteira?\\n\\nGrande abraço,\\nRufino\";\nconst SCHEMA = {\n  type: 'object', additionalProperties: false,\n  required: ['usar', 'mensagem', 'motivo'],\n  properties: {\n    usar: { type: 'boolean' },\n    mensagem: { type: 'string' },\n    motivo: { type: 'string' }\n  }\n};\nfunction limpar(s) { return String(s == null ? '' : s).replace(/\\s+/g, ' ').trim(); }\nfunction escolaDoBloco(b) {\n  var m = String(b || '').match(/<b>Escola atual:<\\/b>\\s*([^<]+)/);\n  return m ? limpar(m[1]) : null;\n}\nreturn $input.all().map(function (it) {\n  var j = it.json;\n  var rapport = [];\n  try { rapport = (typeof j.rapport === 'string' ? JSON.parse(j.rapport) : (j.rapport || [])).map(function (x) { return limpar(x.texto); }).filter(Boolean); } catch (e) { rapport = []; }\n  var entrada = {\n    contato: { nome: j.nome, primeiro_nome: j.primeiro_nome, titulo_no_perfil: limpar(j.titulo), escola_no_cadastro: j.instituicao || null },\n    pesquisa: { escola_atual: escolaDoBloco(j.bloco_cartao), trajetoria: j.trajetoria || null, tempo_de_casa: j.tempo_de_casa || null, rapport: rapport, confianca: j.confianca },\n    mensagem_modelo: j.mensagem_modelo\n  };\n  return { json: Object.assign({}, j, {\n    llm_body: {\n      model: 'claude-opus-5-5',\n      max_tokens: 16000,\n      fallbacks: 'default',\n      output_config: { effort: 'medium', format: { type: 'json_schema', schema: SCHEMA } },\n      system: SISTEMA,\n      messages: [{ role: 'user', content: JSON.stringify(entrada) }]\n    }\n  }) };\n});\n" } }
});

const claude = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Claude Escrever',
    parameters: {
      method: 'POST',
      url: 'https://api.anthropic.com/v1/messages',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'anthropicApi',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [
        { name: 'anthropic-version', value: '2023-06-01' },
        { name: 'anthropic-beta', value: 'server-side-fallback-2026-07-01' }
      ] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.llm_body) }}'),
      options: { timeout: 120000, batching: { batch: { batchSize: 1, batchInterval: 500 } }, response: { response: { neverError: true } } }
    },
    credentials: { anthropicApi: newCredential('Anthropic API - Pesquisa') }
  }
});

const validar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Validar', parameters: { mode: 'runOnceForAllItems', jsCode: "// Confere a mensagem escrita pela IA antes de gravar. Qualquer falha: não grava (fica a mensagem modelo).\nvar saida = [];\nvar pedidos = $('Montar Pedido').all();\n$input.all().forEach(function (it, i) {\n  var resp = it.json || {};\n  var base = (pedidos[i] || {}).json || {};\n  var r = { connection_id: base.connection_id, nome: base.nome, ok: false, motivo: '', mensagem: null };\n  try {\n    if (resp.error) throw new Error('API: ' + (resp.error.type || '') + ' ' + (resp.error.message || ''));\n    if (resp.stop_reason !== 'end_turn') throw new Error('stop_reason ' + resp.stop_reason);\n    var txt = (resp.content || []).filter(function (c) { return c.type === 'text'; }).map(function (c) { return c.text; }).join('');\n    var o = JSON.parse(txt);\n    if (!o.usar) throw new Error('IA não usou: ' + o.motivo);\n    var m = String(o.mensagem || '').replace(/\\r/g, '').trim();\n    var modelo = String(base.mensagem_modelo || '').replace(/\\r/g, '').split('\\n');\n    var linhas = m.split('\\n');\n    if (linhas[0] !== modelo[0]) throw new Error('saudação diferente do modelo');\n    if (m.indexOf(modelo[2]) < 0) throw new Error('agradecimento diferente do modelo');\n    if (!/\\n\\nGrande abraço,\\nRufino$/.test(m)) throw new Error('assinatura diferente');\n    if ((m.match(/\\?/g) || []).length !== 2) throw new Error('precisa de exatamente uma pergunta além do \"Tudo bem?\"');\n    if (/[—–]/.test(m)) throw new Error('travessão');\n    if (/nos conectamos|https?:|www\\.|linkedin\\.com|rocketreach|zoominfo|escavador/i.test(m)) throw new Error('termo proibido');\n    if (/[*\"“”]/.test(m)) throw new Error('negrito ou aspas');\n    var palavras = m.split(/\\s+/).length;\n    if (palavras > 110 || palavras < 35) throw new Error('tamanho fora do padrão: ' + palavras + ' palavras');\n    if (m.indexOf(base.primeiro_nome) < 0) throw new Error('sem o primeiro nome');\n    r.ok = true; r.mensagem = m; r.motivo = o.motivo || '';\n    r.modelo_usado = resp.model || null;\n  } catch (e) { r.motivo = String(e.message || e).slice(0, 300); }\n  saida.push({ json: r });\n});\nreturn saida;\n" } }
});

const somenteOk = node({
  type: 'n8n-nodes-base.filter',
  version: 2.3,
  config: {
    name: 'Somente Aprovadas na Validação',
    parameters: { conditions: { combinator: 'and', options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
      conditions: [{ leftValue: expr('{{ $json.ok }}'), rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }] } }
  }
});

const gravar = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Gravar Versão',
    parameters: {
      operation: 'executeQuery',
      query: "SELECT * FROM rufino_linkedin.save_auto_message($1::uuid, $2, $3, 'WF-06', $4);",
      options: { queryReplacement: expr("{{ [ $json.connection_id, $json.mensagem, 'auto-pesquisa:' + ($json.modelo_usado || 'claude-opus-5-5'), String($execution.id) ] }}") }
    },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

export default workflow('wf-06', 'WF-06 - Mensagem Personalizada (Pesquisa) - Rufino LinkedIn DEV')
  .add(agenda)
  .to(contatos)
  .to(montar)
  .to(claude)
  .to(validar)
  .to(somenteOk)
  .to(gravar);
