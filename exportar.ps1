<#
Exporta o ambiente Claude Code desta maquina para uma pasta portatil.

Uso:  .\exportar.ps1 -Destino 'D:\claude-backup'
      .\exportar.ps1 -Destino 'D:\claude-backup' -IncluirHistorico   # + as conversas (pesado)
      .\exportar.ps1 -Destino 'D:\claude-backup' -Compactar          # + .tgz para transferir
      .\exportar.ps1 -Destino 'D:\claude-backup' -IncluirSegredos    # + credenciais de sessao

O pacote leva as credenciais dos servidores MCP e, com -IncluirHistorico, o conteudo
das conversas. Trate-o como material sensivel: cada pessoa gera o seu.

Requer node no PATH (acompanha a instalacao do Claude Code via npm).
#>
param(
    [Parameter(Mandatory)][string]$Destino,
    [switch]$IncluirHistorico,
    [switch]$IncluirSegredos,
    [switch]$Compactar
)

$ErrorActionPreference = 'Stop'

# robocopy aguenta caminho longo (>260 chars), ao contrario de Copy-Item
function Copiar-Arvore {
    param([string]$De, [string]$Para)
    $saida = robocopy $De $Para /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE) em $De`n$saida" }
    $global:LASTEXITCODE = 0
}

function Copiar-Arquivo {
    param([string]$De, [string]$ParaPasta)
    $saida = robocopy (Split-Path $De -Parent) $ParaPasta (Split-Path $De -Leaf) /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE) em $De`n$saida" }
    $global:LASTEXITCODE = 0
}

$origem = Join-Path $env:USERPROFILE '.claude'
$alvoClaude = Join-Path $Destino '.claude'
New-Item -ItemType Directory -Force -Path $alvoClaude | Out-Null

# O pacote carrega credenciais de MCP e o conteudo das conversas. Exportar para dentro de
# um repositorio versionado e o caminho mais curto para publicar tudo isso por acidente.
$pasta = Get-Item $Destino
while ($pasta) {
    if (Test-Path (Join-Path $pasta.FullName '.git')) {
        Write-Host ''
        Write-Warning "O destino esta dentro do repositorio git em $($pasta.FullName)."
        Write-Warning 'O pacote contem credenciais de MCP e o conteudo das suas conversas.'
        Write-Warning 'Confira o .gitignore antes de commitar, ou exporte para fora do repositorio.'
        Write-Host ''
        break
    }
    $pasta = $pasta.Parent
}

# --- 1. Configuracao declarativa: o que de fato define o ambiente ---
foreach ($arquivo in @('settings.json', 'settings.local.json', 'CLAUDE.md', 'mcp.json', 'keybindings.json')) {
    $caminho = Join-Path $origem $arquivo
    if (Test-Path $caminho) {
        Copiar-Arquivo -De $caminho -ParaPasta $alvoClaude
        Write-Host "  ok  .claude\$arquivo"
    }
}

foreach ($pasta in @('hooks', 'skills', 'commands', 'agents', 'plugins')) {
    $caminho = Join-Path $origem $pasta
    if (Test-Path $caminho) {
        Copiar-Arvore -De $caminho -Para (Join-Path $alvoClaude $pasta)
        $bytes = 0
        $arquivos = 0
        try {
            $medida = Get-ChildItem $caminho -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum
            $bytes = $medida.Sum
            $arquivos = $medida.Count
        } catch { }
        # KB abaixo de 1 MB: hooks e commands tem poucos KB, e "0,0 MB" parece pasta vazia
        $tamanho = if ($bytes -ge 1MB) { "{0:N1} MB" -f ($bytes / 1MB) } else { "{0:N0} KB" -f ($bytes / 1KB) }
        Write-Host ("  ok  .claude\{0}\  ({1} arquivos, {2})" -f $pasta, $arquivos, $tamanho)
    }
}

# --- 2. Memorias por projeto (o historico .jsonl fica de fora por padrao) ---
$projetosOrigem = Join-Path $origem 'projects'
if (Test-Path $projetosOrigem) {
    foreach ($projeto in Get-ChildItem $projetosOrigem -Directory) {
        $alvo = Join-Path $alvoClaude ('projects\' + $projeto.Name)
        $memoria = Join-Path $projeto.FullName 'memory'
        if (Test-Path $memoria) {
            $n = (Get-ChildItem $memoria -File).Count
            if ($n -gt 0) {
                Copiar-Arvore -De $memoria -Para (Join-Path $alvo 'memory')
                Write-Host "  ok  memory: $($projeto.Name) ($n arquivos)"
            }
        }
        $indice = Join-Path $projeto.FullName 'sessions-index.json'
        if (Test-Path $indice) { Copiar-Arquivo -De $indice -ParaPasta $alvo }
        if ($IncluirHistorico) {
            $jsonl = Get-ChildItem $projeto.FullName -Filter *.jsonl -File
            if ($jsonl) {
                $jsonl | ForEach-Object { Copiar-Arquivo -De $_.FullName -ParaPasta $alvo }
                Write-Host "  ok  historico: $($projeto.Name) ($($jsonl.Count) sessoes)"
            }
        }
    }
}

# history.jsonl = prompts digitados (setas para cima); file-history = checkpoints do /rewind
if ($IncluirHistorico) {
    $prompts = Join-Path $origem "history.jsonl"
    if (Test-Path $prompts) {
        Copiar-Arquivo -De $prompts -ParaPasta $alvoClaude
        $n = (Get-Content $prompts | Measure-Object -Line).Lines
        Write-Host "  ok  history.jsonl ($n prompts digitados)"
    }
    $checkpoints = Join-Path $origem "file-history"
    if (Test-Path $checkpoints) {
        Copiar-Arvore -De $checkpoints -Para (Join-Path $alvoClaude "file-history")
        $n = (Get-ChildItem $checkpoints -Directory).Count
        Write-Host "  ok  file-history ($n sessoes com checkpoint)"
    }
}

# --- settings.local.json de cada projeto ---
# Costuma estar no gitignore: nao vem pelo clone e nao vive em ~/.claude.
$helperLocais = Join-Path $PSScriptRoot "lib\locais.js"
if ((Test-Path $helperLocais) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperLocais coletar $Destino
    if ($LASTEXITCODE -ne 0) { throw "falha ao coletar os settings.local.json de projeto" }
}

# --- 3. ~/.claude.json: extrai MCPs + config por projeto ---
# Parsing em node de proposito: ConvertFrom-Json do PS 5.1 e case-insensitive e
# estoura se houver chaves de projeto que diferem so na caixa (c:/... e C:/...).
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $claudeJson) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Warning 'node nao encontrado. Copie ~/.claude.json manualmente e reaproveite so mcpServers/projects.'
    } else {
        $js = @'
const fs = require('fs');
const [entrada, saida] = process.argv.slice(2);
const dados = JSON.parse(fs.readFileSync(entrada, 'utf8'));
const CHAVES = ['mcpServers','enabledMcpjsonServers','disabledMcpjsonServers','allowedTools','hasTrustDialogAccepted'];
const projetos = {};
for (const [caminho, cfg] of Object.entries(dados.projects || {})) {
  const limpo = {};
  for (const chave of CHAVES) if (cfg[chave] !== undefined) limpo[chave] = cfg[chave];
  if (Object.keys(limpo).length) projetos[caminho] = limpo;
}
fs.writeFileSync(saida, JSON.stringify({ mcpServers: dados.mcpServers || {}, projects: projetos }, null, 2), 'utf8');
console.log('MCPs: ' + Object.keys(dados.mcpServers || {}).join(', '));
console.log('projetos com config: ' + Object.keys(projetos).length);
'@
        $helper = Join-Path $env:TEMP 'claude-extrair-config.js'
        $js | Out-File $helper -Encoding utf8
        $parcial = Join-Path $Destino 'claude-json-parcial.json'
        $resumo = node $helper $claudeJson $parcial
        if ($LASTEXITCODE -ne 0) { throw "falha ao extrair config de $claudeJson" }
        Remove-Item $helper -Force
        Write-Host '  ok  claude-json-parcial.json'
        $resumo | ForEach-Object { Write-Host "      $_" }
    }

    if ($IncluirSegredos) {
        Copiar-Arquivo -De $claudeJson -ParaPasta $Destino
        $cred = Join-Path $origem '.credentials.json'
        if (Test-Path $cred) { Copiar-Arquivo -De $cred -ParaPasta $Destino }
        Write-Warning 'O pacote agora contem .claude.json e .credentials.json: token OAuth e senhas em texto claro. Transporte criptografado.'
    }
}

# --- 4. Os proprios scripts, para rodar o import de dentro do pacote ---
foreach ($script in @("exportar.ps1", "extrair.ps1", "importar.ps1", "verificar.ps1", "README.md", "GUIA.md")) {
    $caminho = Join-Path $PSScriptRoot $script
    if (Test-Path $caminho) {
        Copiar-Arquivo -De $caminho -ParaPasta $Destino
        Write-Host "  ok  $script"
    } else {
        Write-Warning "$script nao esta ao lado deste script: copie a mao para o pacote."
    }
}

# a pasta lib/ acompanha: extrair.ps1, importar.ps1 e verificar.ps1 dependem dela
$libOrigem = Join-Path $PSScriptRoot "lib"
if (Test-Path $libOrigem) {
    Copiar-Arvore -De $libOrigem -Para (Join-Path $Destino "lib")
    Write-Host "  ok  lib/"
} else {
    Write-Warning "pasta lib/ ausente: o pacote nao vai conseguir se verificar no destino."
}

# --- 5. Manifesto do ambiente ---
$manifesto = @(
    '# Ambiente Claude Code exportado'
    ''
    "Origem: $env:COMPUTERNAME / usuario $env:USERNAME"
    "Perfil: $env:USERPROFILE"
    ''
    '## Dependencias a instalar no destino'
)
foreach ($dep in @(@('Claude Code CLI','claude'), @('Node','node'), @('.NET SDK','dotnet'), @('Git','git'))) {
    if (Get-Command $dep[1] -ErrorAction SilentlyContinue) {
        $manifesto += "- $($dep[0]): $(& $dep[1] --version)"
    }
}
$manifesto += @('', '## Pacotes npm globais')
# npm escreve avisos no stderr e o PS 5.1 os promove a erro terminante sob
# ErrorActionPreference=Stop: sem isso, um "npm notice" derruba o export inteiro.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $saidaNpm = npm ls -g --depth=0 2>$null
        if ($saidaNpm) { $manifesto += $saidaNpm }
    } catch {
        $manifesto += "  (nao foi possivel listar os pacotes globais)"
    }
    $ErrorActionPreference = $anterior
    $global:LASTEXITCODE = 0
}
$manifesto += @('', '## Extensoes VSCode da Anthropic')
Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -like 'anthropic*' | ForEach-Object { $manifesto += "- $($_.Name)" }
$manifesto | Out-File (Join-Path $Destino 'MANIFESTO.md') -Encoding utf8
Write-Host '  ok  MANIFESTO.md'

# --- 6. Inventario: o import usa para detectar transferencia incompleta ---
$helperInv = Join-Path $PSScriptRoot "lib\inventario.js"
if ((Test-Path $helperInv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperInv gerar $Destino
    if ($LASTEXITCODE -ne 0) { throw "falha ao gerar o inventario" }
} else {
    Write-Warning "inventario.js ausente ou sem node: pacote sem verificacao de integridade."
}

$total = $null
try { $total = (Get-ChildItem $Destino -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum).Sum / 1MB } catch { }
Write-Host ''
if ($null -ne $total) { Write-Host ("Pronto: {0}  ({1:N1} MB)" -f $Destino, $total) }
else { Write-Host "Pronto: $Destino" }

# --- 7. Compactacao opcional para transferir ---
# tar de proposito: Compress-Archive do PS DESCARTA arquivos e pastas ocultas
# (os .git dos marketplaces de plugin se perdem, 29 arquivos no caso testado).
if ($Compactar) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Warning "tar nao encontrado. NAO use Compress-Archive: ele perde os .git dos plugins."
    } else {
        $pai = Split-Path $Destino -Parent
        $nome = (Split-Path $Destino -Leaf) + ".tgz"
        $arquivo = Join-Path $pai $nome
        tar -czf $arquivo -C $Destino .
        if ($LASTEXITCODE -ne 0) { throw "tar falhou" }
        $mb = (Get-Item $arquivo).Length / 1MB
        Write-Host ""
        Write-Host ("Compactado: {0}  ({1:N1} MB)" -f $arquivo, $mb)
        Write-Host "No PC novo:  tar -xzf $nome -C <pasta de destino>"
    }
}
