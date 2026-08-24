// Inventario do pacote: garante que a transferencia (rede, nuvem, zip) chegou completa.
//
// uso: node inventario.js gerar    <pasta do pacote>
//      node inventario.js verificar <pasta do pacote>
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const ui = require('./ui');

const [modo, raiz] = process.argv.slice(2);
const NOME = 'INVENTARIO.txt';

function listar(dir, base = dir) {
  const itens = [];
  for (const entrada of fs.readdirSync(dir, { withFileTypes: true })) {
    const completo = path.join(dir, entrada.name);
    if (entrada.isDirectory()) { itens.push(...listar(completo, base)); continue; }
    const relativo = path.relative(base, completo).split(path.sep).join(String.fromCharCode(47));
    if (relativo === NOME) continue;              // o inventario nao se inventaria
    itens.push({ caminho: relativo, bytes: fs.statSync(completo).size });
  }
  return itens.sort((a, b) => a.caminho.localeCompare(b.caminho));
}

// hash da lista (caminho + tamanho), nao do conteudo: rapido e pega arquivo faltando ou truncado
const assinar = (itens) =>
  crypto.createHash('sha256')
        .update(itens.map(i => `${i.caminho}|${i.bytes}`).join('\n'))
        .digest('hex');

if (!fs.existsSync(raiz)) { console.error(`nao encontrei ${raiz}`); process.exit(1); }
const arquivoInventario = path.join(raiz, NOME);

if (modo === 'gerar') {
  const itens = listar(raiz);
  const bytes = itens.reduce((soma, i) => soma + i.bytes, 0);
  const linhas = [
    `arquivos: ${itens.length}`,
    `bytes: ${bytes}`,
    `assinatura: ${assinar(itens)}`,
    '',
    ...itens.map(i => `${i.bytes}\t${i.caminho}`),
  ];
  fs.writeFileSync(arquivoInventario, linhas.join('\n'), 'utf8');
  ui.item(NOME, ui.juntarDetalhe(`${itens.length} arquivos`, `${(bytes / 1048576).toFixed(1)} MB`));
  process.exit(0);
}

if (modo === 'verificar') {
  if (!fs.existsSync(arquivoInventario)) {
    ui.item('integridade', `sem ${NOME} no pacote`, 'neutro');
    process.exit(0);
  }
  const texto = fs.readFileSync(arquivoInventario, 'utf8').replace(/^\uFEFF/, '');
  const [cabecalho, corpo = ''] = texto.split('\n\n');
  const esperado = Object.fromEntries(
    cabecalho.split('\n').map(l => l.split(': ')).filter(p => p.length === 2)
  );
  const esperadosPorCaminho = new Map(
    corpo.split('\n').filter(l => l.trim()).map(l => {
      const [bytes, ...resto] = l.split('\t');
      return [resto.join('\t'), Number(bytes)];
    })
  );

  const atuais = listar(raiz);
  const atuaisPorCaminho = new Map(atuais.map(i => [i.caminho, i.bytes]));

  const faltando = [...esperadosPorCaminho.keys()].filter(c => !atuaisPorCaminho.has(c));
  const truncados = [...esperadosPorCaminho.entries()]
    .filter(([c, b]) => atuaisPorCaminho.has(c) && atuaisPorCaminho.get(c) !== b);
  const extras = atuais.filter(i => !esperadosPorCaminho.has(i.caminho));

  if (assinar(atuais) === esperado.assinatura) {
    ui.item('integridade do pacote', `${atuais.length} arquivos conferem`);
    process.exit(0);
  }

  ui.item(`o pacote nao confere com o ${NOME}`, '', 'erro');
  ui.nota(`esperado ${esperado.arquivos} arquivos, encontrado ${atuais.length}`);
  for (const caminho of faltando.slice(0, 10)) ui.nota(`FALTA     ${caminho}`, 6);
  if (faltando.length > 10) ui.nota(`... e mais ${faltando.length - 10} faltando`, 6);
  for (const [c, b] of truncados.slice(0, 10)) {
    ui.nota(`TAMANHO   ${c} (esperado ${b}, achou ${atuaisPorCaminho.get(c)})`, 6);
  }
  for (const extra of extras.slice(0, 5)) ui.nota(`EXTRA     ${extra.caminho}`, 6);
  process.exit(2);   // o import decide se para
}

console.error('modo deve ser "gerar" ou "verificar"');
process.exit(1);
