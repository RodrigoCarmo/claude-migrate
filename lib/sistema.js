// Checagens contra a maquina: o executavel esta no PATH, o arquivo existe, o script
// chegou marcado como vindo de fora. Nada aqui executa codigo de terceiros.

const fs = require('fs');
const path = require('path');

const WINDOWS = process.platform === 'win32';

// Executaveis embutidos no shell: nao estao no PATH e procura-los so gera ruido.
const EMBUTIDOS = new Set([
  'cd', 'echo', 'exit', 'if', 'else', 'fi', 'for', 'while', 'do', 'done', 'then',
  'set', 'export', 'source', 'test', 'true', 'false', 'read', 'return', 'shift',
  'cat', 'cp', 'mv', 'rm', 'ls', 'mkdir', 'pwd', 'sleep', 'wait', 'eval', 'exec',
  'write-host', 'write-output', 'get-content', 'set-content', 'test-path', 'join-path',
  'foreach-object', 'where-object', 'select-object', 'out-file', 'new-item', 'get-item',
  'param', 'function', 'try', 'catch', 'finally', 'throw', 'return',
]);

const INTERPRETADOR_POR_EXTENSAO = {
  '.ps1': 'powershell',
  '.js': 'node',
  '.mjs': 'node',
  '.cjs': 'node',
  '.py': 'python',
  '.sh': 'bash',
  '.bash': 'bash',
  '.rb': 'ruby',
  '.pl': 'perl',
};

// Resolve um nome de executavel contra o PATH, respeitando PATHEXT no Windows.
const cacheDoPath = new Map();
function noPath(nome) {
  if (!nome) return null;
  const chave = nome.toLowerCase();
  if (cacheDoPath.has(chave)) return cacheDoPath.get(chave);

  let achado = null;
  const temSeparador = nome.includes('/') || nome.includes('\\');

  if (temSeparador) {
    achado = fs.existsSync(nome) ? path.resolve(nome) : null;
  } else {
    const extensoes = WINDOWS
      ? (process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD;.PS1').split(';').filter(Boolean)
      : [''];
    const pastas = (process.env.PATH || '').split(WINDOWS ? ';' : ':').filter(Boolean);

    busca:
    for (const pasta of pastas) {
      for (const ext of ['', ...extensoes]) {
        const candidato = path.join(pasta, nome + ext);
        try {
          if (fs.existsSync(candidato) && fs.statSync(candidato).isFile()) {
            achado = candidato;
            break busca;
          }
        } catch { /* pasta inacessivel no PATH: ignora */ }
      }
    }
  }

  cacheDoPath.set(chave, achado);
  return achado;
}

// Mark of the Web: arquivo que atravessou uma transferencia carrega este stream e
// a politica de execucao pode recusa-lo. Num hook, isso significa falhar aberto.
function temMarcaDeOrigem(arquivo) {
  if (!WINDOWS) return false;
  try {
    fs.readFileSync(`${arquivo}:Zone.Identifier`);
    return true;
  } catch {
    return false;
  }
}

// Um caminho absoluto de perfil de usuario que nao existe aqui quase sempre significa
// configuracao herdada de outra maquina.
function pareceDeOutroPerfil(caminho) {
  if (!caminho) return false;
  const perfilAtual = (process.env.USERPROFILE || '').toLowerCase();
  const alvo = caminho.toLowerCase();
  const ehDePerfil = /^[a-z]:[\\/]users[\\/]/.test(alvo) || alvo.startsWith('/users/') || alvo.startsWith('/home/');
  if (!ehDePerfil) return false;
  return perfilAtual ? !alvo.startsWith(perfilAtual.toLowerCase()) : false;
}

function temVariavelNaoExpandida(texto) {
  return /\$\{[A-Z_][A-Z0-9_]*\}|%[A-Z_][A-Z0-9_]*%|\$env:/i.test(texto || '');
}

// Extrai de uma linha de comando o executavel e os scripts que ela referencia.
function analisarComando(command, args) {
  const resultado = { executavel: null, scripts: [], variaveis: temVariavelNaoExpandida(command) };
  if (!command) return resultado;

  // exec form: o command e o proprio executavel, sem interpretacao de shell
  if (Array.isArray(args)) {
    resultado.executavel = command;
    for (const arg of args) {
      if (ehCaminhoDeScript(arg)) resultado.scripts.push(limparAspas(arg));
      if (temVariavelNaoExpandida(arg)) resultado.variaveis = true;
    }
    return resultado;
  }

  // shell form: procura caminhos de script em qualquer posicao
  const comAspas = command.match(/'([^']+)'|"([^"]+)"/g) || [];
  for (const trecho of comAspas) {
    const nu = limparAspas(trecho);
    if (ehCaminhoDeScript(nu)) resultado.scripts.push(nu);
  }
  for (const token of command.split(/\s+/)) {
    const nu = limparAspas(token);
    if (ehCaminhoDeScript(nu) && !resultado.scripts.includes(nu)) resultado.scripts.push(nu);
  }

  // primeiro token que nao seja operador vira o executavel candidato
  for (const token of command.trim().split(/\s+/)) {
    const nu = limparAspas(token);
    if (!nu || nu === '&' || nu === '.' || nu.startsWith('-')) continue;
    if (ehCaminhoDeScript(nu)) break;                   // script invocado direto, sem interpretador
    resultado.executavel = nu;
    break;
  }

  return resultado;
}

const limparAspas = (texto) => (texto || '').replace(/^['"]|['"]$/g, '');

function ehCaminhoDeScript(texto) {
  if (!texto) return false;
  const semAspas = limparAspas(texto);
  const ext = path.extname(semAspas).toLowerCase();
  return Object.prototype.hasOwnProperty.call(INTERPRETADOR_POR_EXTENSAO, ext);
}

function interpretadorDe(arquivo) {
  return INTERPRETADOR_POR_EXTENSAO[path.extname(arquivo || '').toLowerCase()] || null;
}

// Ferramentas externas que valem ser sinalizadas quando um texto as invoca.
//
// Reconhecer por lista, e nao por forma, foi decisao deliberada: a versao anterior
// tentava deduzir o executavel pela posicao na linha e produzia dezenas de falsos
// positivos por arquivo, capturando variaveis de shell, palavras-chave de SQL e nomes
// de classe. Um relatorio assim faz o leitor ignorar o relatorio inteiro.
//
// O custo e conhecido: uma ferramenta fora desta lista nao e detectada. Preferimos
// poucos sinais confiaveis a muitos sinais inuteis, e o relatorio declara esse limite.
const FERRAMENTAS_CONHECIDAS = new Set([
  // runtimes e gerenciadores
  'node', 'npm', 'npx', 'pnpm', 'yarn', 'bun', 'deno',
  'python', 'python3', 'py', 'pip', 'pip3', 'poetry', 'uv', 'uvx', 'pipx',
  'ruby', 'gem', 'bundle', 'perl', 'php', 'composer',
  'java', 'javac', 'mvn', 'gradle', 'kotlin',
  'dotnet', 'nuget', 'msbuild',
  'go', 'cargo', 'rustc', 'rustup',
  // versionamento e plataforma
  'git', 'gh', 'glab', 'svn', 'hg',
  // containers e infra
  'docker', 'docker-compose', 'podman', 'kubectl', 'helm', 'minikube',
  'terraform', 'tofu', 'ansible', 'vagrant', 'packer',
  'aws', 'az', 'gcloud', 'firebase', 'heroku', 'flyctl', 'vercel', 'wrangler',
  // bancos
  'psql', 'mysql', 'mongo', 'mongosh', 'redis-cli', 'sqlcmd', 'sqlite3', 'bcp',
  // utilitarios de linha de comando
  'jq', 'yq', 'curl', 'wget', 'rg', 'fd', 'fzf', 'sed', 'awk', 'grep', 'tar',
  'zip', 'unzip', '7z', 'ffmpeg', 'imagemagick', 'convert', 'pandoc',
  'make', 'cmake', 'ninja', 'just', 'task',
  'pwsh', 'powershell', 'bash', 'sh', 'zsh', 'fish', 'cmd', 'wsl',
  'ssh', 'scp', 'rsync', 'robocopy', 'openssl', 'gpg',
  'code', 'vim', 'nvim', 'emacs',
  'claude', 'ollama',
]);

// Procura invocacoes de ferramentas conhecidas em blocos de codigo de shell.
// Pista, nunca veredito: o resultado alimenta a lista "CONFIRME" do relatorio.
function executaveisCitados(texto) {
  if (!texto) return [];
  const candidatos = new Set();

  // so blocos marcados como shell: prosa e codigo de outra linguagem geram ruido
  const blocos = [...texto.matchAll(/```(\w*)\n([\s\S]*?)```/g)]
    .filter(([, lang]) => !lang || /^(bash|sh|shell|zsh|console|powershell|ps1|pwsh|cmd|bat)$/i.test(lang))
    .map(([, , corpo]) => corpo);

  // um script inteiro (sem cercas) entra como corpo unico
  const corpos = blocos.length ? blocos : [texto];

  for (const corpo of corpos) {
    for (const linha of corpo.split('\n')) {
      const limpa = linha.trim();
      if (!limpa || limpa.startsWith('#') || limpa.startsWith('//') || limpa.startsWith('<#')) continue;

      // cada token da linha pode ser a ferramenta: cobre "cat x | jq ." e "& node y"
      for (const bruto of limpa.split(/[\s|;&(){}]+/)) {
        const nome = limparAspas(bruto).toLowerCase();
        if (!nome || nome.startsWith('$') || nome.startsWith('-')) continue;
        const base = nome.replace(/\.(exe|cmd|bat|ps1)$/, '');
        if (FERRAMENTAS_CONHECIDAS.has(base)) candidatos.add(base);
      }
    }
  }

  return [...candidatos];
}

module.exports = {
  WINDOWS,
  noPath,
  temMarcaDeOrigem,
  pareceDeOutroPerfil,
  temVariavelNaoExpandida,
  analisarComando,
  interpretadorDe,
  executaveisCitados,
  EMBUTIDOS,
};
