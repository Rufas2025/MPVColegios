// Monta a mensagem do balanço semanal (WF-07) a partir do JSON da consulta. Texto para o Anderson, não para lead.
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function pct(r, e) { return e ? Math.round((100 * r) / e) + '%' : '0%'; }
var b = ($input.first().json || {}).balanco || {};
if (typeof b === 'string') b = JSON.parse(b);
var L = [];
L.push('📊 <b>Balanço LinkedIn: semana de ' + esc(b.semana) + '</b>');
L.push('');
L.push('<b>Na semana</b>');
L.push('Aceites novos: ' + (b.aceites_semana || 0));
L.push('Mensagens enviadas: ' + (b.enviadas_semana || 0) + (b.enviadas_semana ? ' (já responderam: ' + (b.responderam_das_enviadas_semana || 0) + ')' : ''));
var rs = b.respostas_na_semana || [];
L.push('Respostas registradas: ' + rs.length + (rs.length ? ' (' + rs.map(esc).join(', ') + ')' : ''));
L.push('');
L.push('<b>Desde o começo</b>');
L.push('Enviadas: ' + (b.total_enviadas || 0) + ' · Responderam: ' + (b.total_responderam || 0) + ' (' + pct(b.total_responderam || 0, b.total_enviadas || 0) + ')');
L.push('Por tipo de mensagem:');
(b.por_tipo || []).forEach(function (x) { L.push('• ' + esc(x.nome) + ': ' + x.responderam + ' de ' + x.enviadas + ' (' + pct(x.responderam, x.enviadas) + ')'); });
L.push('Por perfil:');
(b.por_perfil || []).forEach(function (x) { L.push('• ' + esc(x.nome) + ': ' + x.responderam + ' de ' + x.enviadas + ' (' + pct(x.responderam, x.enviadas) + ')'); });
var pouco = (b.por_tipo || []).some(function (x) { return x.enviadas < 20; });
if (pouco) L.push('<i>Algum grupo ainda tem menos de 20 enviadas: a comparação ainda é fraca.</i>');
L.push('');
L.push('<b>Pendências</b>');
L.push('Cartões esperando aprovação: ' + (b.aguardando_aprovacao || 0));
L.push('Aprovadas sem marcar como enviada: ' + (b.falta_marcar_enviada || 0));
var sr = b.sem_resposta_7d_nomes || [];
L.push('Sem resposta há mais de 7 dias: ' + (b.sem_resposta_7d || 0) + (sr.length ? ' (' + sr.map(esc).join(', ') + (b.sem_resposta_7d > sr.length ? '...' : '') + ')' : ''));
L.push('');
L.push('Quando alguém responder no LinkedIn, mande aqui: /respondeu Nome. Sem isso, a resposta só entra na conta no lembrete de follow-up.');
return [{ json: { texto: L.join('\n').slice(0, 4000) } }];
