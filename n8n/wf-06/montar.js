// Monta o pedido à API do Claude para cada contato (WF-06, fase 2, 26/11/2026).
const SISTEMA = __SISTEMA__;
const SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['usar', 'mensagem', 'motivo'],
  properties: {
    usar: { type: 'boolean' },
    mensagem: { type: 'string' },
    motivo: { type: 'string' }
  }
};
function limpar(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }
function escolaDoBloco(b) {
  var m = String(b || '').match(/<b>Escola atual:<\/b>\s*([^<]+)/);
  return m ? limpar(m[1]) : null;
}
return $input.all().map(function (it) {
  var j = it.json;
  var rapport = [];
  try { rapport = (typeof j.rapport === 'string' ? JSON.parse(j.rapport) : (j.rapport || [])).map(function (x) { return limpar(x.texto); }).filter(Boolean); } catch (e) { rapport = []; }
  var entrada = {
    contato: { nome: j.nome, primeiro_nome: j.primeiro_nome, titulo_no_perfil: limpar(j.titulo), escola_no_cadastro: j.instituicao || null },
    pesquisa: { escola_atual: escolaDoBloco(j.bloco_cartao), trajetoria: j.trajetoria || null, tempo_de_casa: j.tempo_de_casa || null, rapport: rapport, confianca: j.confianca },
    mensagem_modelo: j.mensagem_modelo
  };
  return { json: Object.assign({}, j, {
    llm_body: {
      model: 'claude-opus-5-5',
      max_tokens: 16000,
      fallbacks: 'default',
      output_config: { effort: 'medium', format: { type: 'json_schema', schema: SCHEMA } },
      system: SISTEMA,
      messages: [{ role: 'user', content: JSON.stringify(entrada) }]
    }
  }) };
});
