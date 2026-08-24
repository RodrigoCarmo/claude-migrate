// Coleta e restaura o .claude/settings.local.json de cada projeto.
//
// Esse arquivo costuma estar no gitignore: nao vem pelo clone e nao vive em ~/.claude.
// Sem ele, a maquina nova perde as permissoes ja aprovadas de cada repositorio e a
// pessoa reaprova tudo de novo sem entender por que.
//
// uso: node locais.js coletar  <pasta do pacote>
//      node locais.js restaurar <pasta do pacote> [simular]

const fs = require('fs');
const path = require('path');
const cfg = require('./config');

const SUBPASTA = 'projetos-locais';
const INDICE = 'indice.json';
const ARQUIVO = path.join('.claude', 'settings.local.json');

const gerarSlug = (caminho) => caminho.replace(/[^a-zA-Z0-9]/g, '-');

function coletar(pacote) {
  const claudeJson = cfg.lerClaudeJson();
  const projetos = cfg.projetosConhecidos(claudeJson);
  const destino = path.join(pacote, SUBPASTA);
  const indice = [];

  // O mesmo repositorio aparece mais de uma vez no .claude.json quando a letra do
  // drive vem em caixas diferentes (terminal e editor divergem). E o mesmo arquivo:
  // coletar duas vezes so gera ruido no relatorio do import.
  const jaColetados = new Set();

  for (const projeto of projetos) {
    const chave = projeto.toLowerCase();
    if (jaColetados.has(chave)) continue;

    const origem = path.join(projeto, ARQUIVO);
    if (!fs.existsSync(origem)) continue;
    jaColetados.add(chave);

    const slug = gerarSlug(projeto);
    const pasta = path.join(destino, slug);
    fs.mkdirSync(pasta, { recursive: true });
    fs.copyFileSync(origem, path.join(pasta, 'settings.local.json'));
    indice.push({ projeto, slug });
  }

  if (!indice.length) {
    console.log('  --  nenhum settings.local.json de projeto encontrado');
    return 0;
  }

  fs.mkdirSync(destino, { recursive: true });
  fs.writeFileSync(path.join(destino, INDICE), JSON.stringify(indice, null, 2), 'utf8');
  console.log(`  ok  settings.local.json de ${indice.length} projeto(s)`);
  return 0;
}

function restaurar(pacote, simular) {
  const arquivoIndice = path.join(pacote, SUBPASTA, INDICE);
  if (!fs.existsSync(arquivoIndice)) return 0;

  let indice;
  try {
    indice = JSON.parse(fs.readFileSync(arquivoIndice, 'utf8').replace(/^﻿/, ''));
  } catch {
    console.log('  --  indice de projetos ilegivel, pulando');
    return 0;
  }

  let devolvidos = 0;
  let semPasta = 0;
  let mantidos = 0;

  for (const entrada of indice) {
    // so devolve para projeto que existe aqui: criar .claude solto poluiria o disco
    if (!fs.existsSync(entrada.projeto)) { semPasta++; continue; }

    const origem = path.join(pacote, SUBPASTA, entrada.slug, 'settings.local.json');
    if (!fs.existsSync(origem)) continue;

    const destino = path.join(entrada.projeto, ARQUIVO);
    // nunca sobrescreve: o arquivo local da maquina de destino pode ser mais novo
    if (fs.existsSync(destino)) { mantidos++; continue; }

    if (!simular) {
      fs.mkdirSync(path.dirname(destino), { recursive: true });
      fs.copyFileSync(origem, destino);
    }
    devolvidos++;
  }

  const partes = [`${simular ? 'devolveria' : 'devolvidos'} ${devolvidos}`];
  if (mantidos) partes.push(`${mantidos} ja existiam e foram mantidos`);
  if (semPasta) partes.push(`${semPasta} sem a pasta do projeto aqui`);
  console.log(`  ok  settings.local.json: ${partes.join(', ')}`);
  return 0;
}

const [modo, pacote, flag] = process.argv.slice(2);
if (!pacote) {
  console.error('uso: node locais.js <coletar|restaurar> <pasta do pacote> [simular]');
  process.exit(1);
}
if (modo === 'coletar') process.exit(coletar(pacote));
if (modo === 'restaurar') process.exit(restaurar(pacote, flag === 'simular'));
console.error('modo deve ser "coletar" ou "restaurar"');
process.exit(1);
