// Verifica se o ambiente importado consegue rodar nesta maquina.
//
// Dois niveis de confianca, sempre separados:
//   GARANTIDO   lido da configuracao e do disco. Se falha aqui, esta quebrado.
//   SINALIZADO  extraido do corpo de arquivos. Aponta suspeita, nunca declara falha.
//
// Nao executa nada de terceiros: rodar hooks alheios tem efeito colateral real.

const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const sis = require('./sistema');
const ui = require('./ui');

const problemas = [];   // garantido: precisa corrigir
const suspeitas = [];   // sinalizado: confirmar
const validar = [];     // so o dono do ambiente pode dizer
const linhas = [];      // resumo por categoria

const registrar = (categoria, total, ruins, detalhe) =>
  linhas.push({ categoria, total, ruins, detalhe });

// ---------------------------------------------------------------- hooks

function verificarHooks(escoposSettings, escoposPlugins) {
  const hooks = cfg.extrairHooks([...escoposSettings, ...escoposPlugins]);
  let ruins = 0;

  for (const hook of hooks) {
    const rotulo = `${hook.evento}${hook.matcher ? ' ' + hook.matcher : ''}`;
    const analise = sis.analisarComando(hook.command, hook.args);
    let quebrado = false;

    for (const script of analise.scripts) {
      if (sis.temVariavelNaoExpandida(script)) continue;   // so resolve em execucao
      if (!fs.existsSync(script)) {
        quebrado = true;
        const motivo = sis.pareceDeOutroPerfil(script)
          ? 'aponta para o perfil de outra maquina'
          : 'arquivo nao existe aqui';
        problemas.push({
          onde: `hook ${rotulo} (${hook.escopo})`,
          oque: `${motivo}: ${script}`,
          comoResolver: 'reimporte o ambiente ou corrija o caminho no settings.json',
        });
        continue;
      }
      if (sis.temMarcaDeOrigem(script)) {
        quebrado = true;
        problemas.push({
          onde: `hook ${rotulo} (${hook.escopo})`,
          oque: `script marcado como vindo de fora: a politica de execucao pode recusa-lo`,
          comoResolver: `Unblock-File '${script}'`,
        });
      }
      const interpretador = sis.interpretadorDe(script);
      if (interpretador && !sis.noPath(interpretador)) {
        quebrado = true;
        problemas.push({
          onde: `hook ${rotulo} (${hook.escopo})`,
          oque: `precisa de "${interpretador}", que nao esta no PATH`,
          comoResolver: `instale ${interpretador} nesta maquina`,
        });
      }
      // executaveis chamados de dentro do script: pista, nao veredito
      try {
        for (const citado of sis.executaveisCitados(fs.readFileSync(script, 'utf8'))) {
          if (!sis.noPath(citado)) {
            suspeitas.push({ onde: `hook ${path.basename(script)}`, oque: `invoca "${citado}", que nao esta no PATH` });
          }
        }
      } catch { /* sem permissao de leitura: nada a sinalizar */ }
    }

    if (analise.executavel && !sis.noPath(analise.executavel)) {
      quebrado = true;
      problemas.push({
        onde: `hook ${rotulo} (${hook.escopo})`,
        oque: `o comando "${analise.executavel}" nao esta no PATH`,
        comoResolver: `instale o que fornece "${analise.executavel}"`,
      });
    }

    if (hook.shell === 'bash' && sis.WINDOWS && !sis.noPath('bash')) {
      quebrado = true;
      problemas.push({
        onde: `hook ${rotulo} (${hook.escopo})`,
        oque: 'declara shell "bash", que nao existe nesta maquina',
        comoResolver: 'instale o Git for Windows ou mude o shell para powershell',
      });
    }

    if (quebrado) ruins++;

    if (cfg.EVENTOS_QUE_BLOQUEIAM.has(hook.evento)) {
      validar.push({
        nome: analise.scripts[0] ? path.basename(analise.scripts[0]) : hook.command.slice(0, 46),
        evento: hook.evento,
        matcher: hook.matcher,
      });
    }
  }

  registrar('Hooks', hooks.length, ruins, `${hooks.length - ruins} executaveis`);
}

// ---------------------------------------------------------------- mcp

function verificarMcp(claudeJson) {
  const servidores = cfg.extrairMcpServers(claudeJson);
  let ruins = 0;

  for (const servidor of servidores) {
    const conf = servidor.cfg || {};
    if (conf.type && conf.type !== 'stdio') continue;    // http/sse nao dependem de binario local
    if (!conf.command) continue;

    if (!sis.noPath(conf.command)) {
      ruins++;
      problemas.push({
        onde: `MCP "${servidor.nome}" (${servidor.origem})`,
        oque: `o comando "${conf.command}" nao esta no PATH: o servidor nao sobe`,
        comoResolver: 'instale o pacote que fornece esse binario (veja o manifesto do pacote)',
      });
      continue;
    }

    for (const arg of conf.args || []) {
      if (typeof arg !== 'string' || sis.temVariavelNaoExpandida(arg)) continue;
      if (/^[A-Za-z]:[\\/]|^\//.test(arg) && !fs.existsSync(arg)) {
        ruins++;
        problemas.push({
          onde: `MCP "${servidor.nome}"`,
          oque: `argumento aponta para caminho inexistente: ${arg}`,
          comoResolver: 'ajuste o caminho na configuracao do servidor',
        });
      }
    }
  }

  registrar('MCP', servidores.length, ruins, `${servidores.length - ruins} com comando disponivel`);
}

// ---------------------------------------------------------------- plugins

function verificarPlugins() {
  const { lista, marketplaces } = cfg.plugins();
  let ruins = 0;

  for (const plugin of lista) {
    if (!plugin.installPath) continue;
    if (!fs.existsSync(plugin.installPath)) {
      ruins++;
      problemas.push({
        onde: `plugin ${plugin.nome}`,
        oque: sis.pareceDeOutroPerfil(plugin.installPath)
          ? `installPath aponta para o perfil de outra maquina: ${plugin.installPath}`
          : `installPath nao existe: ${plugin.installPath}`,
        comoResolver: 'reinstale com /plugin, ou corrija installed_plugins.json',
      });
    }
  }
  registrar('Plugins', lista.length, ruins, `${lista.length - ruins} com caminho valido`);

  let mktRuins = 0;
  for (const mkt of marketplaces) {
    if (mkt.installLocation && !fs.existsSync(mkt.installLocation)) {
      mktRuins++;
      problemas.push({
        onde: `marketplace ${mkt.nome}`,
        oque: `installLocation nao existe: ${mkt.installLocation}`,
        comoResolver: 'readicione com /plugin marketplace add',
      });
    }
  }
  if (marketplaces.length) {
    registrar('Marketplaces', marketplaces.length, mktRuins, `${marketplaces.length - mktRuins} com caminho valido`);
  }
}

// ------------------------------------------------- skills e commands

function varrerPastaDeMarkdown(base, categoria, arquivoEsperado) {
  if (!fs.existsSync(base)) return;
  const itens = [];

  for (const entrada of fs.readdirSync(base, { withFileTypes: true })) {
    if (entrada.isDirectory()) {
      const md = path.join(base, entrada.name, arquivoEsperado);
      if (fs.existsSync(md)) itens.push({ nome: entrada.name, md, pasta: path.join(base, entrada.name) });
    } else if (entrada.name.endsWith('.md')) {
      itens.push({ nome: entrada.name.replace(/\.md$/, ''), md: path.join(base, entrada.name), pasta: base });
    }
  }

  let comSuspeita = 0;
  for (const item of itens) {
    let texto = '';
    try { texto = fs.readFileSync(item.md, 'utf8'); } catch { continue; }

    let sinalizou = false;
    for (const citado of sis.executaveisCitados(texto)) {
      if (!sis.noPath(citado)) {
        suspeitas.push({ onde: `${categoria.toLowerCase()} "${item.nome}"`, oque: `invoca "${citado}", que nao esta no PATH` });
        sinalizou = true;
      }
    }

    // scripts que acompanham o item sao verificaveis com certeza
    if (item.pasta !== base) {
      for (const arquivo of listarArquivos(item.pasta)) {
        const interpretador = sis.interpretadorDe(arquivo);
        if (interpretador && !sis.noPath(interpretador)) {
          problemas.push({
            onde: `${categoria.toLowerCase()} "${item.nome}"`,
            oque: `traz ${path.basename(arquivo)} e "${interpretador}" nao esta no PATH`,
            comoResolver: `instale ${interpretador}`,
          });
        }
      }
    }
    if (sinalizou) comSuspeita++;
  }

  registrar(categoria, itens.length, 0,
    comSuspeita ? `${comSuspeita} com dependencia sinalizada` : `${itens.length} presentes`);
}

function listarArquivos(dir, profundidade = 0) {
  if (profundidade > 2) return [];
  let saida = [];
  let entradas;
  try { entradas = fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
  for (const entrada of entradas) {
    const completo = path.join(dir, entrada.name);
    if (entrada.isDirectory()) saida = saida.concat(listarArquivos(completo, profundidade + 1));
    else saida.push(completo);
  }
  return saida;
}

// ------------------------------------------- permissoes e diretorios

// Regras citam caminho em formatos variados: C:\x, c:/x e //c/x (estilo posix do Windows).
function caminhosDaRegra(regra) {
  const achados = [];
  const padrao = /(\/\/[a-zA-Z]\/[^)"'*\s]*|[a-zA-Z]:[\\/][^)"'*\s]*)/g;
  for (const bruto of regra.match(padrao) || []) {
    let caminho = bruto.replace(/\\\\/g, '\\');
    const posix = caminho.match(/^\/\/([a-zA-Z])\/(.*)$/);
    if (posix) caminho = `${posix[1]}:/${posix[2]}`;
    caminho = caminho.replace(/[\\/]+$/, '');
    if (caminho.length > 4) achados.push(caminho);
  }
  return achados;
}

// So regras de ferramenta de arquivo tem caminho em posicao previsivel. Uma regra
// Bash(...) carrega uma linha de comando inteira, onde extrair caminho gera ruido.
const REGRA_COM_CAMINHO = /^(Read|Edit|Write|Glob|Grep|NotebookEdit)\s*\(/i;

function verificarPermissoes(escopos) {
  let total = 0;
  let ruins = 0;
  const jaVistos = new Set();

  for (const escopo of escopos) {
    const permissoes = (escopo.dados && escopo.dados.permissions) || {};
    for (const grupo of ['allow', 'ask', 'deny']) {
      for (const regra of permissoes[grupo] || []) {
        total++;
        if (!REGRA_COM_CAMINHO.test(regra)) continue;
        for (const caminho of caminhosDaRegra(regra)) {
          const pai = path.dirname(caminho);
          if (fs.existsSync(caminho) || fs.existsSync(pai)) continue;
          if (jaVistos.has(caminho)) continue;
          jaVistos.add(caminho);
          ruins++;
          suspeitas.push({
            onde: `permissao (${escopo.rotulo})`,
            oque: `regra cita caminho que nao existe: ${encurtar(caminho)}`,
          });
        }
      }
    }
  }
  registrar('Permissoes', total, ruins,
    ruins ? `${ruins} citam caminho inexistente` : `${total} regras, caminhos ok`);
}

function verificarDiretorios(escopos) {
  let total = 0;
  let ruins = 0;
  for (const escopo of escopos) {
    const extras = (escopo.dados && escopo.dados.permissions && escopo.dados.permissions.additionalDirectories) || [];
    for (const dir of extras) {
      total++;
      if (!fs.existsSync(dir)) {
        ruins++;
        problemas.push({
          onde: `diretorio adicional (${escopo.rotulo})`,
          oque: `nao existe nesta maquina: ${dir}`,
          comoResolver: 'crie a pasta ou remova a entrada de additionalDirectories',
        });
      }
    }
  }
  if (total) registrar('Diretorios', total, ruins, `${total - ruins} existem`);
}

function verificarStatusLine(escopos) {
  for (const escopo of escopos) {
    const sl = escopo.dados && escopo.dados.statusLine;
    if (!sl || !sl.command) continue;
    const analise = sis.analisarComando(sl.command, sl.args);
    let ruins = 0;
    if (analise.executavel && !sis.noPath(analise.executavel)) {
      ruins++;
      problemas.push({
        onde: `statusLine (${escopo.rotulo})`,
        oque: `o comando "${analise.executavel}" nao esta no PATH`,
        comoResolver: `instale o que fornece "${analise.executavel}"`,
      });
    }
    for (const script of analise.scripts) {
      if (!sis.temVariavelNaoExpandida(script) && !fs.existsSync(script)) {
        ruins++;
        problemas.push({
          onde: `statusLine (${escopo.rotulo})`,
          oque: `script nao existe: ${script}`,
          comoResolver: 'corrija o caminho ou remova a statusLine',
        });
      }
    }
    registrar('statusLine', 1, ruins, ruins ? 'com problema' : 'pronta');
  }
}

const encurtar = (texto, max = 62) =>
  texto.length <= max ? texto : texto.slice(0, max - 3) + '...';

// ---------------------------------------------------------------- saida

function imprimir() {
  ui.cabecalho('verificar', 'o que deste ambiente consegue rodar nesta maquina');

  const ondeEstamos = { 'ambiente': path.join(cfg.perfil(), '.claude') };
  // O verificar.ps1 passa isto quando sabe de qual pacote o ambiente veio: sem
  // essa linha o relatorio fala de uma maquina sem dizer contra o que ela bate.
  if (process.env.CM_ORIGEM) ondeEstamos['importado'] = process.env.CM_ORIGEM;
  ui.contexto(ondeEstamos);

  ui.secao('Inventario');
  for (const linha of linhas) {
    ui.item(
      linha.categoria,
      ui.juntarDetalhe(`${linha.total} declarados`, linha.detalhe),
      linha.ruins ? 'aviso' : 'ok'
    );
  }

  if (problemas.length) {
    ui.secao('CORRIJA');
    ui.nota('impede o item de funcionar', 0);
    for (const problema of problemas) {
      ui.item(problema.onde, '', 'erro');
      ui.nota(problema.oque);
      if (problema.comoResolver) ui.nota(problema.comoResolver);
    }
  }

  if (suspeitas.length) {
    ui.secao('CONFIRME');
    ui.nota('sinalizado a partir do texto, pode ser falso positivo', 0);
    for (const suspeita of suspeitas) {
      ui.item(suspeita.onde, '', 'aviso');
      ui.nota(suspeita.oque);
    }
  }

  if (validar.length) {
    ui.secao('VALIDE A MAO');
    ui.nota('conseguem rodar, mas so voce sabe se ainda decidem o que deveriam', 0);
    for (const item of validar) {
      ui.item(item.nome, ui.juntarDetalhe(item.evento, item.matcher), 'info');
    }
  }

  const flexionar = (quantidade, umSo, varios) => `${quantidade} ${quantidade === 1 ? umSo : varios}`;

  const contagem = {};
  if (problemas.length) contagem['corrija'] = flexionar(problemas.length, 'item impede', 'itens impedem') + ' o funcionamento';
  if (suspeitas.length) contagem['confirme'] = flexionar(suspeitas.length, 'item sinalizado', 'itens sinalizados');
  if (validar.length) contagem['valide'] = flexionar(validar.length, 'hook pode', 'hooks podem') + ' bloquear acoes';

  const estado = problemas.length ? 'erro' : (suspeitas.length ? 'aviso' : 'ok');
  const titulo = problemas.length
    ? 'Verificacao concluida com pendencias'
    : 'Ambiente pronto para uso';

  ui.resumo(titulo, contagem, estado, ['claude   ->   /login, /mcp, /doctor, /resume']);

  ui.aviso('Nao verificado', [
    'bibliotecas importadas pelos scripts',
    'arquivos de configuracao que eles leiam',
    'a logica de qualquer hook',
  ]);
  console.log('');

  return problemas.length ? 1 : 0;
}

function main() {
  const claudeJson = cfg.lerClaudeJson();
  const projetos = cfg.projetosConhecidos(claudeJson);
  const escopos = cfg.escoposDeSettings(projetos);
  const escoposPlugins = cfg.escoposDePlugins();

  if (!escopos.length) {
    console.log('  Nenhum settings.json encontrado. O ambiente foi importado nesta conta?');
    return 1;
  }

  verificarHooks(escopos, escoposPlugins);
  verificarMcp(claudeJson);
  verificarPlugins();
  varrerPastaDeMarkdown(path.join(cfg.perfil(), '.claude', 'skills'), 'Skills', 'SKILL.md');
  varrerPastaDeMarkdown(path.join(cfg.perfil(), '.claude', 'commands'), 'Commands', 'COMMAND.md');
  verificarPermissoes(escopos);
  verificarDiretorios(escopos);
  verificarStatusLine(escopos);

  return imprimir();
}

process.exit(main());
