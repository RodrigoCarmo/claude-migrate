// Leitura da configuracao do Claude Code em todos os escopos onde ela pode viver.
//
// Node de proposito: ConvertFrom-Json do PowerShell 5.1 e insensivel a maiusculas e
// lanca excecao em .claude.json reais, onde duas chaves de projeto podem diferir
// apenas na caixa da letra do drive.

const fs = require('fs');
const path = require('path');
const os = require('os');

const perfil = () => process.env.USERPROFILE || os.homedir();

function lerJson(caminho) {
  try {
    const texto = fs.readFileSync(caminho, 'utf8').replace(/^\uFEFF/, '');
    return JSON.parse(texto);
  } catch {
    return null;
  }
}

// Os lugares onde settings.json pode estar, em ordem de precedencia crescente.
// Um projeto so entra na lista se a pasta existir nesta maquina.
function escoposDeSettings(projetosConhecidos = []) {
  const base = perfil();
  const escopos = [];

  const add = (rotulo, caminho) => {
    const dados = lerJson(caminho);
    if (dados) escopos.push({ rotulo, caminho, dados });
  };

  add('user', path.join(base, '.claude', 'settings.json'));
  add('user local', path.join(base, '.claude', 'settings.local.json'));

  // politica gerenciada: caminho fixo por plataforma
  if (process.platform === 'win32') {
    add('managed', path.join(process.env.ProgramData || 'C:\\ProgramData', 'ClaudeCode', 'managed-settings.json'));
  } else if (process.platform === 'darwin') {
    add('managed', '/Library/Application Support/ClaudeCode/managed-settings.json');
  } else {
    add('managed', '/etc/claude-code/managed-settings.json');
  }

  for (const projeto of projetosConhecidos) {
    if (!fs.existsSync(projeto)) continue;
    const nome = path.basename(projeto);
    add(`projeto ${nome}`, path.join(projeto, '.claude', 'settings.json'));
    add(`projeto ${nome} (local)`, path.join(projeto, '.claude', 'settings.local.json'));
  }

  return escopos;
}

// Hooks declarados por plugins instalados: plugins/cache/<marketplace>/<plugin>/<versao>/hooks/hooks.json
function escoposDePlugins() {
  const cache = path.join(perfil(), '.claude', 'plugins', 'cache');
  const escopos = [];
  if (!fs.existsSync(cache)) return escopos;

  const percorrer = (dir, profundidade) => {
    if (profundidade > 3) return;
    let entradas;
    try { entradas = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entrada of entradas) {
      if (!entrada.isDirectory()) continue;
      const completo = path.join(dir, entrada.name);
      const arquivoHooks = path.join(completo, 'hooks', 'hooks.json');
      const dados = lerJson(arquivoHooks);
      if (dados) {
        escopos.push({
          rotulo: `plugin ${path.relative(cache, completo).split(path.sep).slice(0, 2).join('/')}`,
          caminho: arquivoHooks,
          dados: dados.hooks ? dados : { hooks: dados },
        });
      }
      percorrer(completo, profundidade + 1);
    }
  };
  percorrer(cache, 0);
  return escopos;
}

// Achata a estrutura hooks[evento][].hooks[] numa lista simples.
function extrairHooks(escopos) {
  const encontrados = [];
  for (const escopo of escopos) {
    const porEvento = (escopo.dados && escopo.dados.hooks) || {};
    for (const [evento, grupos] of Object.entries(porEvento)) {
      if (!Array.isArray(grupos)) continue;
      for (const grupo of grupos) {
        for (const hook of grupo.hooks || []) {
          if (hook.type && hook.type !== 'command') continue;   // http e mcp_tool nao usam disco
          encontrados.push({
            evento,
            matcher: grupo.matcher || '',
            command: hook.command || '',
            args: hook.args || null,
            shell: hook.shell || null,
            timeout: hook.timeout || null,
            escopo: escopo.rotulo,
            origem: escopo.caminho,
          });
        }
      }
    }
  }
  return encontrados;
}

// Eventos que podem impedir uma acao. Falha de hook aqui e brecha, nao inconveniencia.
const EVENTOS_QUE_BLOQUEIAM = new Set([
  'PreToolUse', 'UserPromptSubmit', 'UserPromptExpansion', 'PostToolBatch',
  'SubagentStop', 'TaskCreated', 'TaskCompleted', 'Stop', 'TeammateIdle',
  'ConfigChange', 'WorktreeCreate', 'PreCompact', 'Elicitation', 'ElicitationResult',
]);

function lerClaudeJson() {
  return lerJson(path.join(perfil(), '.claude.json')) || {};
}

function projetosConhecidos(claudeJson) {
  return Object.keys(claudeJson.projects || {});
}

// mcpServers pode vir do .claude.json (escopo user), do mcp.json e do .mcp.json de cada projeto.
function extrairMcpServers(claudeJson) {
  const servidores = [];
  const add = (nome, cfg, origem) => servidores.push({ nome, cfg, origem });

  for (const [nome, cfg] of Object.entries(claudeJson.mcpServers || {})) {
    add(nome, cfg, '.claude.json (user)');
  }

  const arquivoMcp = path.join(perfil(), '.claude', 'mcp.json');
  const doArquivo = lerJson(arquivoMcp);
  if (doArquivo) {
    for (const [nome, cfg] of Object.entries(doArquivo.mcpServers || {})) {
      if (!servidores.some((s) => s.nome === nome)) add(nome, cfg, '.claude/mcp.json');
    }
  }

  for (const [projeto, cfg] of Object.entries(claudeJson.projects || {})) {
    for (const [nome, servidor] of Object.entries(cfg.mcpServers || {})) {
      add(nome, servidor, `projeto ${path.basename(projeto)}`);
    }
  }

  return servidores;
}

function plugins() {
  const base = path.join(perfil(), '.claude', 'plugins');
  const instalados = lerJson(path.join(base, 'installed_plugins.json')) || { plugins: {} };
  const marketplaces = lerJson(path.join(base, 'known_marketplaces.json')) || {};

  const lista = [];
  for (const [nome, entradas] of Object.entries(instalados.plugins || {})) {
    for (const entrada of entradas) {
      lista.push({ nome, installPath: entrada.installPath, versao: entrada.version, escopo: entrada.scope });
    }
  }
  const mkts = Object.entries(marketplaces).map(([nome, cfg]) => ({
    nome,
    installLocation: cfg.installLocation,
  }));
  return { lista, marketplaces: mkts };
}

module.exports = {
  perfil,
  lerJson,
  escoposDeSettings,
  escoposDePlugins,
  extrairHooks,
  EVENTOS_QUE_BLOQUEIAM,
  lerClaudeJson,
  projetosConhecidos,
  extrairMcpServers,
  plugins,
};
