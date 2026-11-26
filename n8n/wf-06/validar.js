// Confere a mensagem escrita pela IA antes de gravar. Qualquer falha: não grava (fica a mensagem modelo).
var saida = [];
var pedidos = $('Montar Pedido').all();
$input.all().forEach(function (it, i) {
  var resp = it.json || {};
  var base = (pedidos[i] || {}).json || {};
  var r = { connection_id: base.connection_id, nome: base.nome, ok: false, motivo: '', mensagem: null };
  try {
    if (resp.error) throw new Error('API: ' + (resp.error.type || '') + ' ' + (resp.error.message || ''));
    if (resp.stop_reason !== 'end_turn') throw new Error('stop_reason ' + resp.stop_reason);
    var txt = (resp.content || []).filter(function (c) { return c.type === 'text'; }).map(function (c) { return c.text; }).join('');
    var o = JSON.parse(txt);
    if (!o.usar) throw new Error('IA não usou: ' + o.motivo);
    var m = String(o.mensagem || '').replace(/\r/g, '').trim();
    var modelo = String(base.mensagem_modelo || '').replace(/\r/g, '').split('\n');
    var linhas = m.split('\n');
    if (linhas[0] !== modelo[0]) throw new Error('saudação diferente do modelo');
    if (m.indexOf(modelo[2]) < 0) throw new Error('agradecimento diferente do modelo');
    if (!/\n\nGrande abraço,\nRufino$/.test(m)) throw new Error('assinatura diferente');
    if ((m.match(/\?/g) || []).length !== 2) throw new Error('precisa de exatamente uma pergunta além do "Tudo bem?"');
    if (/[—–]/.test(m)) throw new Error('travessão');
    if (/nos conectamos|https?:|www\.|linkedin\.com|rocketreach|zoominfo|escavador/i.test(m)) throw new Error('termo proibido');
    if (/[*"“”]/.test(m)) throw new Error('negrito ou aspas');
    var palavras = m.split(/\s+/).length;
    if (palavras > 110 || palavras < 35) throw new Error('tamanho fora do padrão: ' + palavras + ' palavras');
    if (m.indexOf(base.primeiro_nome) < 0) throw new Error('sem o primeiro nome');
    r.ok = true; r.mensagem = m; r.motivo = o.motivo || '';
    r.modelo_usado = resp.model || null;
  } catch (e) { r.motivo = String(e.message || e).slice(0, 300); }
  saida.push({ json: r });
});
return saida;
