<#
Importa o ambiente exportado, no PC novo.

Uso:  .\importar.ps1 -Pacote 'D:\claude-backup' -Simular   # so mostra o que faria
      .\importar.ps1 -Pacote 'D:\claude-backup'

Faz backup de ~/.claude e ~/.claude.json antes de mexer.
#>
param(
    [Parameter(Mandatory)][string]$Pacote,
    [switch]$Simular,
    [hashtable]$RemapearPaths
)

$ErrorActionPreference = 'Stop'

function Copiar-Arvore {
    param([string]$De, [string]$Para)
    $saida = robocopy $De $Para /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE) em $De`n$saida" }
    $global:LASTEXITCODE = 0
}

$origemClaude  = Join-Path $Pacote '.claude'
$destinoClaude = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $origemClaude)) { throw "nao encontrei $origemClaude" }

# --- Integridade: transferencia por nuvem/rede pode chegar incompleta ---
$helperInv = Join-Path $PSScriptRoot "lib\inventario.js"
if ((Test-Path $helperInv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperInv verificar $Pacote
    if ($LASTEXITCODE -eq 2) {
        Write-Host ""
        throw "pacote incompleto: transfira de novo, de preferencia zipado."
    }
    if ($LASTEXITCODE -ne 0) { throw "falha ao verificar o inventario" }
}

# --- 0. Backup do que ja existe aqui ---
if (-not $Simular) {
    if (Test-Path $destinoClaude) {
        $bkp = "$destinoClaude.bkp"
        if (-not (Test-Path $bkp)) { Copiar-Arvore -De $destinoClaude -Para $bkp; Write-Host "  backup: $bkp" }
    }
    $cj = Join-Path $env:USERPROFILE '.claude.json'
    if ((Test-Path $cj) -and -not (Test-Path "$cj.bkp")) {
        Copy-Item $cj -Destination "$cj.bkp"; Write-Host "  backup: $cj.bkp"
    }
}

# --- 1. Arvore .claude ---
if ($Simular) {
    $arquivos = Get-ChildItem $origemClaude -Recurse -File
    Write-Host "  [simular] copiaria $($arquivos.Count) arquivos para $destinoClaude"
    $arquivos | Where-Object { $_.DirectoryName -eq $origemClaude } |
        ForEach-Object { Write-Host "            .claude\$($_.Name)" }
} else {
    Copiar-Arvore -De $origemClaude -Para $destinoClaude
    Write-Host '  ok  arvore .claude copiada'
}

# --- 2. Reescreve caminhos do perfil antigo (hook, additionalDirectories, permissions) ---
$usuarioAntigo = $null
$manifesto = Join-Path $Pacote 'MANIFESTO.md'
if (Test-Path $manifesto) {
    $linha = Get-Content $manifesto | Where-Object { $_ -like 'Perfil:*' } | Select-Object -First 1
    if ($linha) { $usuarioAntigo = Split-Path ($linha -replace '^Perfil:\s*', '') -Leaf }
}
if ($usuarioAntigo -and $usuarioAntigo -ne $env:USERNAME) {
    Write-Host "  usuario mudou: $usuarioAntigo -> $env:USERNAME"
    foreach ($nome in @('settings.json', 'settings.local.json', 'mcp.json')) {
        $arquivo = Join-Path $destinoClaude $nome
        if (-not (Test-Path $arquivo)) { continue }
        $texto = Get-Content $arquivo -Raw -Encoding UTF8
        $novo = $texto.Replace("Users\$usuarioAntigo", "Users\$env:USERNAME").
                       Replace("Users\$usuarioAntigo", "Users\$env:USERNAME").
                       Replace("Users/$usuarioAntigo", "Users/$env:USERNAME")
        if ($novo -ne $texto) {
            if ($Simular) { Write-Host "  [simular] reescreveria caminhos em $nome" }
            else { [IO.File]::WriteAllText($arquivo, $novo, [Text.UTF8Encoding]::new($false)); Write-Host "  ok  caminhos reescritos em $nome" }
        }
    }
    Write-Warning 'Confira a mao: plugins\installed_plugins.json (installPath) e qualquer permission com caminho literal.'
}

# --- 3. Merge de mcpServers e config de projeto no ~/.claude.json ---
# node de proposito: ConvertFrom-Json do PS 5.1 estoura com chaves que diferem so na caixa.
$parcial = Join-Path $Pacote 'claude-json-parcial.json'
if (Test-Path $parcial) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'node nao encontrado. Instale o Node (ou o Claude Code via npm) antes de importar.'
    }
    $js = @'
const fs = require('fs');
const [caminhoParcial, caminhoAlvo, modo] = process.argv.slice(2);
const simular = modo === 'simular';
const novo = JSON.parse(fs.readFileSync(caminhoParcial, 'utf8'));
const atual = fs.existsSync(caminhoAlvo) ? JSON.parse(fs.readFileSync(caminhoAlvo, 'utf8')) : {};
atual.mcpServers ??= {};
atual.projects ??= {};

for (const [nome, cfg] of Object.entries(novo.mcpServers || {})) {
  if (atual.mcpServers[nome]) { console.log(`  --  MCP '${nome}' ja existe, mantido`); continue; }
  if (!simular) atual.mcpServers[nome] = cfg;
  console.log(`  ${simular ? '[simular] adicionaria' : 'ok  adicionado'} MCP '${nome}'`);
}

let importados = 0, ignorados = 0;
for (const [caminho, cfg] of Object.entries(novo.projects || {})) {
  // so traz config de projeto cujo diretorio existe nesta maquina
  if (!fs.existsSync(caminho)) { ignorados++; continue; }
  if (!simular) atual.projects[caminho] = { ...(atual.projects[caminho] || {}), ...cfg };
  importados++;
}
console.log(`  ${simular ? '[simular] ' : 'ok  '}config de projeto: ${importados} importados, ${ignorados} ignorados (caminho inexistente aqui)`);

if (!simular) {
  fs.writeFileSync(caminhoAlvo, JSON.stringify(atual, null, 2), 'utf8');
  console.log('  ok  ~/.claude.json atualizado');
}
'@
    $helper = Join-Path $env:TEMP 'claude-merge-config.js'
    $js | Out-File $helper -Encoding utf8
    $modo = if ($Simular) { 'simular' } else { 'aplicar' }
    node $helper $parcial (Join-Path $env:USERPROFILE '.claude.json') $modo
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
    Write-Host ""
    Write-Host "Historico de sessoes:"
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
    Write-Warning "diagnosticar-historico.js nao esta ao lado deste script; historico nao verificado."
}
Write-Host ''
Write-Host 'Falta fazer a mao:'
Write-Host '  1. npm i -g @anthropic-ai/claude-code     (versao no MANIFESTO.md)'
Write-Host '  2. instalar a extensao do Claude Code no seu editor, se usar'
Write-Host '  3. claude  ->  /login'
Write-Host '  4. /mcp     conferir os servidores'
Write-Host '  5. /doctor  validar hooks, plugins e permissoes'

$verificador = Join-Path $PSScriptRoot "verificar.ps1"
if ((Test-Path $verificador) -and -not $Simular) {
    Write-Host ""
    Write-Host "Verificando o que ficou de pe nesta maquina..." -ForegroundColor Cyan
    & $verificador
} elseif (Test-Path $verificador) {
    Write-Host ""
    Write-Host "Depois de aplicar, rode:  .\verificar.ps1" -ForegroundColor Cyan
}
