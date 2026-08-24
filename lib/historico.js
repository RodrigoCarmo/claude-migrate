// Diagnostica (e opcionalmente remapeia) o historico de sessoes de ~/.claude/projects.
//
// O nome da pasta de projeto e o cwd com [^a-zA-Z0-9] trocado por '-'. O /resume
// so lista sessoes da pasta correspondente ao cwd atual, entao um repo que esta em
// outro caminho no PC novo deixa as sessoes antigas orfas ate serem remapeadas.
//
// uso: node diagnosticar-historico.js <pasta projects> [<mapeamento.json>] <simular|aplicar>
const fs = require('fs');
const path = require('path');
const ui = require('./ui');

const [pastaProjects, arquivoMapeamento, modo] = process.argv.slice(2);
const simular = modo === 'simular';
const mapeamento = arquivoMapeamento && fs.existsSync(arquivoMapeamento)
  ? JSON.parse(fs.readFileSync(arquivoMapeamento, 'utf8').replace(/^\uFEFF/, ''))
  : {};

const gerarSlug = (caminho) => caminho.replace(/[^a-zA-Z0-9]/g, '-');
const EXEMPLO = "-RemapearPaths @{ 'CAMINHO_ANTIGO' = 'CAMINHO_NOVO' }";

function lerCwd(pastaProjeto) {
  for (const arquivo of fs.readdirSync(pastaProjeto).filter(f => f.endsWith('.jsonl'))) {
    for (const linha of fs.readFileSync(path.join(pastaProjeto, arquivo), 'utf8').split('\n')) {
      if (!linha.trim()) continue;
      try { const obj = JSON.parse(linha); if (obj.cwd) return obj.cwd; } catch { }
    }
  }
  return null;
}

function remapear(cwd) {
  for (const [antigo, novo] of Object.entries(mapeamento)) {
    if (cwd.toLowerCase().startsWith(antigo.toLowerCase())) return novo + cwd.slice(antigo.length);
  }
  return null;
}

// troca so o cwd gravado em cada linha, preservando o resto do JSON
function reescreverCwd(textoJsonl, cwdAntigo, cwdNovo) {
  return textoJsonl.split('\n').map(linha => {
    if (!linha.trim()) return linha;
    try {
      const obj = JSON.parse(linha);
      if (obj.cwd && obj.cwd.toLowerCase() === cwdAntigo.toLowerCase()) {
        obj.cwd = cwdNovo;
        return JSON.stringify(obj);
      }
    } catch { }
    return linha;
  }).join('\n');
}

if (!fs.existsSync(pastaProjects)) {
  ui.item('historico', 'sem pasta projects', 'neutro');
  process.exit(0);
}

let acessiveis = 0, orfas = 0;

for (const nomePasta of fs.readdirSync(pastaProjects)) {
  const pastaProjeto = path.join(pastaProjects, nomePasta);
  if (!fs.statSync(pastaProjeto).isDirectory()) continue;

  const sessoes = fs.readdirSync(pastaProjeto).filter(f => f.endsWith('.jsonl'));
  if (!sessoes.length) continue;

  const cwd = lerCwd(pastaProjeto);
  if (!cwd) {
    ui.item(nomePasta, `nao achei cwd nas ${sessoes.length} sessoes`, 'aviso');
    continue;
  }

  const cwdNovo = remapear(cwd);
  const cwdFinal = cwdNovo || cwd;

  if (!fs.existsSync(cwdFinal)) {
    orfas += sessoes.length;
    if (cwdNovo) {
      ui.item(`${sessoes.length} sessoes`, 'destino do remapeamento nao existe', 'aviso');
      ui.nota(`${cwdNovo}   <- crie ou clone essa pasta e rode de novo`);
    } else {
      ui.item(`${sessoes.length} sessoes orfas`, `${cwd} nao existe aqui`, 'aviso');
      ui.nota(`se o repo esta em outro caminho, use ${EXEMPLO}`);
    }
    continue;
  }

  if (!cwdNovo) {
    acessiveis += sessoes.length;
    ui.item(cwdFinal, `${sessoes.length} sessoes`);
    continue;
  }

  const slugNovo = gerarSlug(cwdNovo);
  ui.item(`${sessoes.length} sessoes`, simular ? 'seriam remapeadas' : 'remapeadas', 'info');
  ui.nota(`cwd:   ${cwd}  ->  ${cwdNovo}`);
  ui.nota(`pasta: ${nomePasta}  ->  ${slugNovo}`);
  acessiveis += sessoes.length;
  if (simular) continue;

  const pastaNova = path.join(pastaProjects, slugNovo);
  fs.mkdirSync(pastaNova, { recursive: true });
  for (const arquivo of fs.readdirSync(pastaProjeto)) {
    if (arquivo === 'sessions-index.json') continue;   // cache com fullPath absoluto: sera reconstruido
    const de = path.join(pastaProjeto, arquivo);
    const para = path.join(pastaNova, arquivo);
    if (fs.statSync(de).isDirectory()) {
      fs.cpSync(de, para, { recursive: true });
    } else if (arquivo.endsWith('.jsonl')) {
      fs.writeFileSync(para, reescreverCwd(fs.readFileSync(de, 'utf8'), cwd, cwdNovo), 'utf8');
    } else {
      fs.copyFileSync(de, para);
    }
  }
  if (path.resolve(pastaNova) !== path.resolve(pastaProjeto)) {
    fs.rmSync(pastaProjeto, { recursive: true, force: true });
  }
}

ui.item('total que o /resume vai listar', ui.juntarDetalhe(`${acessiveis} sessoes`, orfas ? `${orfas} orfas` : ''), orfas ? 'aviso' : 'ok');
