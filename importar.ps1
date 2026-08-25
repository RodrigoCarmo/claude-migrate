<#
Importa o ambiente exportado, no PC novo.

Uso:  .\importar.ps1 -Pacote "D:\claude-restore" -Simular   # so mostra o que faria
      .\importar.ps1 -Pacote "D:\claude-restore"

-Pacote e obrigatorio de proposito: e a pasta que voce escolheu ao extrair, e
fica visivel no comando digitado em vez de ser adivinhada.

Faz backup de ~/.claude e ~/.claude.json antes de mexer, um novo a cada import,
carimbado com data e hora, e registra os caminhos em ~\.claude-migrate.json.
#>
param(
    [Parameter(Mandatory)][string]$Pacote,
    [switch]$Simular,
    [hashtable]$RemapearPaths
)

$ErrorActionPreference = 'Stop'

# copia, execucao externa, estado e a camada visual
. (Join-Path $PSScriptRoot "lib\comum.ps1")
Initialize-Ui

$Pacote = [IO.Path]::GetFullPath($Pacote)
$origemClaude  = Join-Path $Pacote '.claude'
$destinoClaude = Join-Path $env:USERPROFILE '.claude'

Show-Cabecalho -Comando $(if ($Simular) { 'importar (simulacao)' } else { 'importar' }) `
    -Descricao $(if ($Simular) { 'mostra o que seria feito, sem escrever nada' } else { 'aplica o ambiente do pacote nesta maquina' })

Show-Contexto ([ordered]@{
    'pacote ' = $Pacote
    'destino' = $destinoClaude
})

if (-not (Test-Path $origemClaude)) {
    Show-Erro 'a pasta informada nao parece um pacote de migracao' @(
        "nao encontrei $origemClaude",
        'aponte -Pacote para a pasta que o extrair.ps1 gerou'
    )
    exit 1
}

# --- Integridade: transferencia por nuvem/rede pode chegar incompleta ---
Show-Secao 'Conferindo o pacote'
$helperInv = Join-Path $PSScriptRoot "lib\inventario.js"
if ((Test-Path $helperInv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperInv verificar $Pacote
    if ($LASTEXITCODE -eq 2) {
        Show-Erro 'pacote incompleto' @('transfira de novo, de preferencia compactado')
        exit 1
    }
    if ($LASTEXITCODE -ne 0) { throw "falha ao verificar o inventario" }
}

# --- 0. Backup do que ja existe aqui ---
# Um backup por import, carimbado com data e hora, e nada e sobrescrito. O mais
# antigo continua sendo o registro do ambiente original, e cada import seguinte
# ganha o seu proprio ponto de retorno. Guardar apenas o primeiro deixava o
# trabalho feito entre dois imports fora do ambiente vivo e fora do backup.
#
# Os caminhos vao para o estado no fim: e o que permite desfazer depois sem
# depender de voce ter guardado o scrollback do terminal.
$backupClaude = $null
$backupClaudeJson = $null
if (-not $Simular) {
    Show-Secao 'Backup do ambiente atual'

    # o mesmo carimbo nos dois: e o que mostra, olhando a pasta do perfil, que
    # aquele .claude e aquele .claude.json sairam do mesmo import
    $carimbo = (Get-Date).ToString('yyyyMMdd-HHmmss')

    if (Test-Path $destinoClaude) {
        $bkp = Get-CaminhoLivre "$destinoClaude.bkp.$carimbo"
        Copiar-Arvore -De $destinoClaude -Para $bkp -Mensagem "backup do ambiente atual"
        Show-Item -Texto '.claude' -Detalhe $bkp
        $backupClaude = $bkp
    } else {
        Show-Item -Texto '.claude' -Detalhe 'nao havia ambiente aqui' -Estado 'neutro'
    }

    $cj = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path $cj) {
        $bkpJson = Get-CaminhoLivre "$cj.bkp.$carimbo"
        Copy-Item $cj -Destination $bkpJson
        Show-Item -Texto '.claude.json' -Detalhe $bkpJson
        $backupClaudeJson = $bkpJson
    }

    # um backup inteiro por import ocupa espaco, e o .claude carrega as
    # transcricoes: quem migra varias vezes precisa ver a pilha crescer
    $acumulados = @(Get-ChildItem $env:USERPROFILE -Filter '.claude.bkp*' -Directory -Force -ErrorAction SilentlyContinue)
    if ($acumulados.Count -gt 1) {
        Show-Nota "$(Format-Plural $acumulados.Count 'backup') de .claude em $env:USERPROFILE, apague os que nao precisa mais"
    }
}

# --- 1. Arvore .claude ---
Show-Secao 'Configuracao'
if ($Simular) {
    # Arvore de plugin aninhada passa de 260 chars e o Get-ChildItem para ali, mas
    # o robocopy do modo real atravessa. A simulacao nao pode abortar onde a
    # aplicacao de verdade passaria: conta o que alcanca e declara o que faltou.
    $errosLeitura = @()
    $arquivos = @(Get-ChildItem $origemClaude -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable errosLeitura)
    Show-Item -Texto 'arvore .claude' -Detalhe "$($arquivos.Count) arquivos seriam copiados" -Estado 'info'
    if ($errosLeitura.Count -gt 0) {
        Show-Nota "+$($errosLeitura.Count) pastas que o Windows nao lista por caminho longo"
        Show-Nota 'a copia usa robocopy e alcanca essas pastas'
    }
    $arquivos | Where-Object { $_.DirectoryName -eq $origemClaude } |
        ForEach-Object { Show-Nota ".claude\$($_.Name)" }
} else {
    Copiar-Arvore -De $origemClaude -Para $destinoClaude -Mensagem "aplicando a configuracao"
    Show-Item -Texto 'arvore .claude' -Detalhe 'copiada'
}

# --- 2. Reescreve caminhos do perfil antigo (hook, additionalDirectories, permissions) ---
$usuarioAntigo = $null
$manifesto = Join-Path $Pacote 'MANIFESTO.md'
if (Test-Path $manifesto) {
    $linha = Get-Content $manifesto | Where-Object { $_ -like 'Perfil:*' } | Select-Object -First 1
    if ($linha) { $usuarioAntigo = Split-Path ($linha -replace '^Perfil:\s*', '') -Leaf }
}
if ($usuarioAntigo -and $usuarioAntigo -ne $env:USERNAME) {
    Show-Item -Texto 'usuario mudou' -Detalhe "$usuarioAntigo  ->  $env:USERNAME" -Estado 'aviso'
    foreach ($nome in @('settings.json', 'settings.local.json', 'mcp.json')) {
        $arquivo = Join-Path $destinoClaude $nome
        if (-not (Test-Path $arquivo)) { continue }
        $texto = Get-Content $arquivo -Raw -Encoding UTF8
        $novo = $texto.Replace("Users\$usuarioAntigo", "Users\$env:USERNAME").
                       Replace("Users/$usuarioAntigo", "Users/$env:USERNAME")
        if ($novo -ne $texto) {
            if ($Simular) {
                Show-Item -Texto $nome -Detalhe 'caminhos seriam reescritos' -Estado 'info' -Recuo 2
            } else {
                [IO.File]::WriteAllText($arquivo, $novo, [Text.UTF8Encoding]::new($false))
                Show-Item -Texto $nome -Detalhe 'caminhos reescritos' -Recuo 2
            }
        }
    }
    Show-Aviso 'Confira a mao' @(
        'plugins\installed_plugins.json (installPath)',
        'qualquer permission com caminho literal'
    )
}

# --- 3. Merge de mcpServers e config de projeto no ~/.claude.json ---
# node de proposito: ConvertFrom-Json do PS 5.1 estoura com chaves que diferem so na caixa.
Show-Secao 'Integracoes'
$parcial = Join-Path $Pacote 'claude-json-parcial.json'
if (Test-Path $parcial) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'node nao encontrado. Instale o Node (ou o Claude Code via npm) antes de importar.'
    }
    $js = @'
const fs = require('fs');
const ui = require(process.argv[5]);
const [caminhoParcial, caminhoAlvo, modo] = process.argv.slice(2);
const simular = modo === 'simular';
const novo = JSON.parse(fs.readFileSync(caminhoParcial, 'utf8'));
const atual = fs.existsSync(caminhoAlvo) ? JSON.parse(fs.readFileSync(caminhoAlvo, 'utf8')) : {};
atual.mcpServers ??= {};
atual.projects ??= {};

for (const [nome, cfg] of Object.entries(novo.mcpServers || {})) {
  if (atual.mcpServers[nome]) { ui.item(`MCP ${nome}`, 'ja existe aqui, mantido', 'neutro'); continue; }
  if (!simular) atual.mcpServers[nome] = cfg;
  ui.item(`MCP ${nome}`, simular ? 'seria adicionado' : 'adicionado', simular ? 'info' : 'ok');
}

let importados = 0, ignorados = 0;
for (const [caminho, cfg] of Object.entries(novo.projects || {})) {
  // so traz config de projeto cujo diretorio existe nesta maquina
  if (!fs.existsSync(caminho)) { ignorados++; continue; }
  if (!simular) atual.projects[caminho] = { ...(atual.projects[caminho] || {}), ...cfg };
  importados++;
}
ui.item('config por projeto',
  ui.juntarDetalhe(`${importados} importados`, ignorados ? `${ignorados} sem pasta aqui` : ''),
  ignorados ? 'aviso' : 'ok');

if (!simular) {
  fs.writeFileSync(caminhoAlvo, JSON.stringify(atual, null, 2), 'utf8');
  ui.item('~/.claude.json', 'atualizado');
}
'@
    $helper = Join-Path $env:TEMP 'claude-merge-config.js'
    $js | Out-File $helper -Encoding utf8
    $modo = if ($Simular) { 'simular' } else { 'aplicar' }
    $caminhoUi = (Join-Path $PSScriptRoot 'lib\ui.js') -replace '\\', '/'
    node $helper $parcial (Join-Path $env:USERPROFILE '.claude.json') $modo $caminhoUi
    if ($LASTEXITCODE -ne 0) { throw 'falha no merge do .claude.json' }
    Remove-Item $helper -Force
}

# --- settings.local.json de volta a cada projeto que existe aqui ---
$helperLocais = Join-Path $PSScriptRoot "lib\locais.js"
if ((Test-Path $helperLocais) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    $modoLocais = if ($Simular) { "simular" } else { "aplicar" }
    node $helperLocais restaurar $Pacote $modoLocais
    if ($LASTEXITCODE -ne 0) { throw "falha ao restaurar os settings.local.json de projeto" }
}

# --- 4. Historico de sessoes: confere se o /resume vai achar, e remapeia se o caminho mudou ---
$helperHist = Join-Path $PSScriptRoot "lib\historico.js"
$pastaProjects = Join-Path $destinoClaude "projects"
if ((Test-Path $helperHist) -and (Test-Path $pastaProjects)) {
    Show-Secao 'Historico de sessoes'
    $mapaArquivo = ""
    if ($RemapearPaths -and $RemapearPaths.Count -gt 0) {
        $mapaArquivo = Join-Path $env:TEMP "claude-remapeamento.json"
        # ConvertTo-Json de hashtable com 1 item nao vira objeto no PS 5.1: forca com [ordered]
        $ordenado = [ordered]@{}
        foreach ($par in $RemapearPaths.GetEnumerator()) { $ordenado[$par.Key] = $par.Value }
        [IO.File]::WriteAllText($mapaArquivo, ($ordenado | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    $modoHist = if ($Simular) { "simular" } else { "aplicar" }
    node $helperHist $pastaProjects $mapaArquivo $modoHist
    if ($LASTEXITCODE -ne 0) { throw "falha ao diagnosticar o historico" }
} elseif (Test-Path $pastaProjects) {
    Show-Item -Texto 'historico' -Detalhe 'historico.js ausente: nao verificado' -Estado 'aviso'
}

# --- Anotar que este pacote foi aplicado ---
if (-not $Simular) {
    $agora = (Get-Date).ToString('o')
    $null = Set-EstadoMigracao @{
        pacote      = $Pacote
        importadoEm = $agora
        backups     = [ordered]@{
            claude     = $backupClaude
            claudeJson = $backupClaudeJson
        }
    }
    # as chaves acima sao sobrescritas pelo proximo import. O historico e o que
    # permite ao restaurar.ps1 dizer de onde veio cada backup da lista.
    $null = Add-HistoricoMigracao ([ordered]@{
        acao             = 'import'
        quando           = $agora
        pacote           = $Pacote
        backupClaude     = $backupClaude
        backupClaudeJson = $backupClaudeJson
    })
}

# --- Fechamento ---
if ($Simular) {
    Show-Resumo -Titulo 'Simulacao concluida, nada foi escrito' -Estado 'info' -Proximo @(
        "Se os numeros acima batem, aplique de verdade:",
        ".\importar.ps1 -Pacote `"$Pacote`""
    )
    Write-Host ''
    return
}

# o caminho carimbado nao cabe inteiro duas vezes na linha do resumo: o .claude
# vai completo, e do .claude.json basta o nome do arquivo
$resumoBackups = 'nao havia ambiente anterior'
if ($backupClaude) {
    $resumoBackups = $backupClaude
    if ($backupClaudeJson) { $resumoBackups += "  (e $(Split-Path $backupClaudeJson -Leaf))" }
}

Show-Resumo -Titulo 'Ambiente importado' -Campos ([ordered]@{
    'pacote'  = $Pacote
    'backups' = $resumoBackups
}) -Proximo @(
    '1. npm i -g @anthropic-ai/claude-code      (versao no MANIFESTO.md)',
    '2. instale a extensao do Claude Code no seu editor, se usar',
    '3. claude   ->   /login, /mcp, /doctor, /resume'
)

$verificador = Join-Path $PSScriptRoot "verificar.ps1"
if (Test-Path $verificador) { & $verificador }
