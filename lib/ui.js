// Camada de apresentacao do lado Node, espelho de lib/ui.ps1.
//
// O verificador roda em Node, mas sai no mesmo terminal que os scripts
// PowerShell. Sem esta simetria, a ultima tela da migracao teria outra
// gramatica visual que todas as anteriores.
//
// Quem chama define CM_UNICODE e CM_LARGURA: o processo PowerShell ja detectou
// as capacidades do console e nao ha por que redescobri-las aqui, com menos
// informacao. Sem essas variaveis, cai numa deteccao propria conservadora.

const temTty = Boolean(process.stdout.isTTY);
const usaCor = !process.env.NO_COLOR && temTty;

const usaUnicode = process.env.CM_UNICODE
  ? process.env.CM_UNICODE === '1'
  : Boolean(process.env.WT_SESSION || process.env.TERM_PROGRAM);

const largura = (() => {
  const informada = parseInt(process.env.CM_LARGURA, 10);
  if (Number.isFinite(informada) && informada > 0) return informada;
  const doTty = process.stdout.columns;
  if (doTty) return Math.max(56, Math.min(88, doTty - 4));
  return 76;
})();

const CORES = {
  reset: '\x1b[0m',
  branco: '\x1b[97m',
  cinza: '\x1b[37m',
  fraco: '\x1b[90m',
  verde: '\x1b[32m',
  vermelho: '\x1b[31m',
  amarelo: '\x1b[33m',
  ciano: '\x1b[36m',
  magenta: '\x1b[35m',
};

const pinta = (texto, cor) => (usaCor && CORES[cor] ? CORES[cor] + texto + CORES.reset : texto);

const GLIFOS = usaUnicode
  ? { ok: '✓', erro: '✗', aviso: '⚠', info: 'ℹ', seta: '➜',
      ponto: '·', losango: '◆', pendente: '○', linha: '─' }
  : { ok: '+', erro: 'x', aviso: '!', info: 'i', seta: '>',
      ponto: '-', losango: '*', pendente: 'o', linha: '-' };

const ESTILOS = {
  ok: { glifo: 'ok', cor: 'verde' },
  erro: { glifo: 'erro', cor: 'vermelho' },
  aviso: { glifo: 'aviso', cor: 'amarelo' },
  info: { glifo: 'info', cor: 'ciano' },
  neutro: { glifo: 'ponto', cor: 'fraco' },
  pendente: { glifo: 'pendente', cor: 'fraco' },
};

const juntarDetalhe = (...partes) => partes.filter(Boolean).join(`  ${GLIFOS.ponto}  `);

function cabecalho(comando, descricao) {
  console.log('');
  console.log(
    `  ${pinta(GLIFOS.losango, 'magenta')} ${pinta('claude-migrate', 'branco')}` +
    `  ${pinta(GLIFOS.ponto, 'fraco')}  ${pinta(comando, 'magenta')}`
  );
  if (descricao) console.log(pinta(`     ${descricao}`, 'fraco'));
  console.log('');
}

function contexto(campos) {
  const chaves = Object.keys(campos);
  const largo = Math.max(...chaves.map((chave) => chave.length));
  for (const chave of chaves) {
    console.log(`  ${pinta(chave.padEnd(largo), 'fraco')}  ${pinta(String(campos[chave]), 'ciano')}`);
  }
  console.log('');
}

function secao(titulo) {
  console.log('');
  console.log(`  ${pinta(titulo, 'branco')}`);
}

// O alinhamento a direita e o que transforma uma lista de frases numa tabela
// legivel de relance. Detalhe longo demais empurra e nao quebra a linha.
function item(texto, detalhe, estado = 'ok', recuo = 0) {
  const estilo = ESTILOS[estado] || ESTILOS.ok;
  const espaco = ' '.repeat(recuo);
  const marca = pinta(GLIFOS[estilo.glifo], estilo.cor);
  let linha = `  ${espaco}${marca} ${pinta(texto, 'cinza')}`;

  if (detalhe) {
    const usado = 4 + recuo + texto.length;
    const preenchimento = Math.max(1, largura - usado - detalhe.length);
    linha += ' '.repeat(preenchimento) + pinta(detalhe, 'fraco');
  }
  console.log(linha);
}

function nota(texto, recuo = 4) {
  console.log(pinta(' '.repeat(recuo + 2) + texto, 'fraco'));
}

function divisor() {
  console.log(pinta('  ' + GLIFOS.linha.repeat(largura), 'fraco'));
}

function aviso(texto, detalhes = []) {
  console.log('');
  console.log(`  ${pinta(GLIFOS.aviso, 'amarelo')}  ${pinta(texto, 'amarelo')}`);
  for (const detalhe of detalhes) console.log(pinta(`     ${detalhe}`, 'fraco'));
}

function resumo(titulo, campos = {}, estado = 'ok', proximo = []) {
  const estilo = ESTILOS[estado] || ESTILOS.ok;
  console.log('');
  divisor();
  console.log('');
  console.log(`  ${pinta(GLIFOS[estilo.glifo], estilo.cor)}  ${pinta(titulo, 'branco')}`);

  const chaves = Object.keys(campos);
  if (chaves.length) {
    console.log('');
    const largo = Math.max(...chaves.map((chave) => chave.length));
    for (const chave of chaves) {
      console.log(`     ${pinta(chave.padEnd(largo), 'fraco')}  ${pinta(String(campos[chave]), 'cinza')}`);
    }
  }

  if (proximo.length) {
    console.log('');
    console.log(`  ${pinta(GLIFOS.seta, 'ciano')}  ${pinta('Proximo passo', 'ciano')}`);
    for (const comando of proximo) console.log(pinta(`     ${comando}`, 'branco'));
  }
  console.log('');
}

module.exports = {
  glifos: GLIFOS, pinta, largura, juntarDetalhe,
  cabecalho, contexto, secao, item, nota, divisor, aviso, resumo,
};
