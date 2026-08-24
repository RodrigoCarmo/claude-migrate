<#
Exporta o ambiente Claude Code desta maquina para um pacote .tgz portatil.

Uso:  .\exportar.ps1 -Destino "$env:USERPROFILE\claude-backup.tgz"
      .\exportar.ps1 -Destino "D:\claude-backup.tgz" -SemHistorico
      .\exportar.ps1 -Destino "D:\claude-backup.tgz" -IncluirSegredos

-Destino e o arquivo que voce quer ter no fim, e e obrigatorio de proposito: o
caminho fica visivel no comando digitado, nao escondido num default. Sem a
extensao .tgz, ela e acrescentada.

O resultado e UM arquivo. A pasta usada para montar o pacote e temporaria, fica
ao lado do destino enquanto o export roda e e removida ao terminar: manter as
duas coisas seria guardar o mesmo ambiente em dobro.

tar, e nao Compress-Archive: o zip do PowerShell descarta arquivos e pastas
ocultas, e os .git dos marketplaces de plugin se perdem (29 arquivos no caso
testado). O arquivo unico tambem atravessa caminho acima de 260 caracteres, que
e onde a arvore de plugins quebra uma copia comum.

O pacote leva as credenciais dos servidores MCP e, sem -SemHistorico, o conteudo
das conversas. Trate-o como material sensivel: cada pessoa gera o seu.

Requer node e tar no PATH (ambos acompanham Windows 10+ e o Claude Code via npm).
#>
param(
    [Parameter(Mandatory)][string]$Destino,
    [switch]$SemHistorico,
    [switch]$IncluirSegredos
)

$ErrorActionPreference = 'Stop'

# copia, execucao externa e a camada visual
. (Join-Path $PSScriptRoot "lib\comum.ps1")
Initialize-Ui

$IncluirHistorico = -not $SemHistorico

$origem = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $origem)) {
    Show-Erro "nao existe ambiente Claude Code neste perfil" @("procurei em $origem")
    exit 1
}

# Sem tar nao ha pacote, e a pasta de montagem seria apagada no fim de qualquer
# forma. Melhor parar antes de copiar 100 MB do que descobrir isso no fim.
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Show-Erro 'tar nao encontrado no PATH' @(
        'o tar acompanha o Windows 10 versao 1803 e posteriores',
        'nao substitua por Compress-Archive: ele descarta os .git dos plugins'
    )
    exit 1
}

# GetFullPath lanca NotSupportedException crua em caminho malformado; o erro
# tratado diz o que fazer, em vez de despejar a excecao do .NET.
try {
    $arquivoTgz = [IO.Path]::GetFullPath($Destino)
} catch {
    Show-Erro 'caminho de destino invalido' @($Destino, 'informe um caminho de arquivo, por exemplo D:\claude-backup.tgz')
    exit 1
}
if (-not $arquivoTgz.EndsWith('.tgz', [StringComparison]::OrdinalIgnoreCase)) {
    $arquivoTgz = "$arquivoTgz.tgz"
}
if (Test-Path $arquivoTgz -PathType Container) {
    Show-Erro 'o destino e uma pasta existente' @($arquivoTgz, 'informe o caminho do arquivo .tgz que voce quer gerar')
    exit 1
}
$pastaDoDestino = Split-Path $arquivoTgz -Parent
if (-not (Test-Path $pastaDoDestino)) { New-Item -ItemType Directory -Force -Path $pastaDoDestino | Out-Null }

# Montagem ao lado do destino, e nao no TEMP: evita atravessar discos com o
# pacote inteiro, e cai no mesmo volume que ja precisa ter espaco para ele.
$Destino = Join-Path $pastaDoDestino ('.' + [IO.Path]::GetFileNameWithoutExtension($arquivoTgz) + '.montagem')
if (Test-Path $Destino) { Remove-Item $Destino -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
$alvoClaude = Join-Path $Destino '.claude'
New-Item -ItemType Directory -Force -Path $alvoClaude | Out-Null

Show-Cabecalho -Comando 'exportar' -Descricao 'coleta o ambiente desta maquina num pacote portatil'

Show-Contexto ([ordered]@{
    'origem ' = $origem
    'destino' = $arquivoTgz
})

# O pacote carrega credenciais de MCP e o conteudo das conversas. Exportar para dentro de
# um repositorio versionado e o caminho mais curto para publicar tudo isso por acidente.
$pasta = Get-Item $pastaDoDestino
while ($pasta) {
    if (Test-Path (Join-Path $pasta.FullName '.git')) {
        Show-Aviso "O destino esta dentro do repositorio git em $($pasta.FullName)" @(
            'o pacote contem credenciais de MCP e o conteudo das suas conversas',
            'confira o .gitignore antes de commitar, ou exporte para fora do repositorio'
        )
        break
    }
    $pasta = $pasta.Parent
}

# --- 1. Configuracao declarativa: o que de fato define o ambiente ---
Show-Secao 'Configuracao'
foreach ($arquivo in @('settings.json', 'settings.local.json', 'CLAUDE.md', 'mcp.json', 'keybindings.json')) {
    $caminho = Join-Path $origem $arquivo
    if (Test-Path $caminho) {
        Copiar-Arquivo -De $caminho -ParaPasta $alvoClaude
        Show-Item -Texto $arquivo -Detalhe (Format-Tamanho (Get-Item $caminho).Length)
    } else {
        Show-Item -Texto $arquivo -Detalhe 'nao existe nesta maquina' -Estado 'neutro'
    }
}

Show-Secao 'Arvores'
foreach ($pasta in @('hooks', 'skills', 'commands', 'agents', 'plugins')) {
    $caminho = Join-Path $origem $pasta
    if (-not (Test-Path $caminho)) {
        Show-Item -Texto $pasta -Detalhe 'nao existe nesta maquina' -Estado 'neutro'
        continue
    }
    Copiar-Arvore -De $caminho -Para (Join-Path $alvoClaude $pasta) -Mensagem "copiando $pasta"
    $bytes = 0
    $arquivos = 0
    try {
        $medida = Get-ChildItem $caminho -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum
        $bytes = $medida.Sum
        $arquivos = $medida.Count
    } catch { }
    # KB abaixo de 1 MB: hooks e commands tem poucos KB, e "0,0 MB" parece pasta vazia
    Show-Item -Texto $pasta -Detalhe (Join-Detalhe @((Format-Plural $arquivos 'arquivo'), (Format-Tamanho $bytes)))
}

# --- 2. Memorias por projeto (o historico .jsonl fica de fora com -SemHistorico) ---
Show-Secao $(if ($IncluirHistorico) { 'Memorias e historico' } else { 'Memorias' })
$projetosOrigem = Join-Path $origem 'projects'
if (Test-Path $projetosOrigem) {
    foreach ($projeto in Get-ChildItem $projetosOrigem -Directory) {
        $alvo = Join-Path $alvoClaude ('projects\' + $projeto.Name)
        $partes = @()

        $memoria = Join-Path $projeto.FullName 'memory'
        if (Test-Path $memoria) {
            $n = (Get-ChildItem $memoria -File).Count
            if ($n -gt 0) {
                Copiar-Arvore -De $memoria -Para (Join-Path $alvo "memory") -Mensagem "memorias de $($projeto.Name)"
                $partes += Format-Plural $n 'memoria'
            }
        }
        $indice = Join-Path $projeto.FullName 'sessions-index.json'
        if (Test-Path $indice) { Copiar-Arquivo -De $indice -ParaPasta $alvo }

        if ($IncluirHistorico) {
            $jsonl = Get-ChildItem $projeto.FullName -Filter *.jsonl -File
            if ($jsonl) {
                $jsonl | ForEach-Object { Copiar-Arquivo -De $_.FullName -ParaPasta $alvo }
                $partes += Format-Plural $jsonl.Count 'sessao' 'sessoes'
            }
        }
        if ($partes.Count -gt 0) {
            Show-Item -Texto $projeto.Name -Detalhe (Join-Detalhe $partes)
        }
    }
}

# history.jsonl = prompts digitados (setas para cima); file-history = checkpoints do /rewind
if ($IncluirHistorico) {
    $prompts = Join-Path $origem "history.jsonl"
    if (Test-Path $prompts) {
        Copiar-Arquivo -De $prompts -ParaPasta $alvoClaude
        $n = (Get-Content $prompts | Measure-Object -Line).Lines
        Show-Item -Texto 'history.jsonl' -Detalhe ((Format-Plural $n 'prompt') + ' digitados')
    }
    $checkpoints = Join-Path $origem "file-history"
    if (Test-Path $checkpoints) {
        Copiar-Arvore -De $checkpoints -Para (Join-Path $alvoClaude "file-history") -Mensagem "checkpoints de arquivo"
        $n = (Get-ChildItem $checkpoints -Directory).Count
        Show-Item -Texto 'file-history' -Detalhe ((Format-Plural $n 'sessao' 'sessoes') + ' com checkpoint')
    }
} else {
    Show-Item -Texto 'historico de conversas' -Detalhe 'fora do pacote (-SemHistorico)' -Estado 'neutro'
}

# --- 3. Integracoes ---
Show-Secao 'Integracoes'

# settings.local.json de cada projeto: costuma estar no gitignore, nao vem pelo
# clone e nao vive em ~/.claude.
$helperLocais = Join-Path $PSScriptRoot "lib\locais.js"
if ((Test-Path $helperLocais) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperLocais coletar $Destino
    if ($LASTEXITCODE -ne 0) { throw "falha ao coletar os settings.local.json de projeto" }
}

# ~/.claude.json: extrai MCPs + config por projeto.
# Parsing em node de proposito: ConvertFrom-Json do PS 5.1 e case-insensitive e
# estoura se houver chaves de projeto que diferem so na caixa (c:/... e C:/...).
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $claudeJson) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Show-Aviso 'node nao encontrado' @('copie ~/.claude.json a mao e reaproveite so mcpServers/projects')
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
console.log(Object.keys(dados.mcpServers || {}).join(', '));
console.log(String(Object.keys(projetos).length));
'@
        $helper = Join-Path $env:TEMP 'claude-extrair-config.js'
        $js | Out-File $helper -Encoding utf8
        $parcial = Join-Path $Destino 'claude-json-parcial.json'
        $resumo = @(node $helper $claudeJson $parcial)
        if ($LASTEXITCODE -ne 0) { throw "falha ao extrair config de $claudeJson" }
        Remove-Item $helper -Force
        Show-Item -Texto 'servidores MCP' -Detalhe $(if ($resumo[0]) { $resumo[0] } else { 'nenhum' })
        Show-Item -Texto 'config por projeto' -Detalhe (Format-Plural ([int]$resumo[1]) 'projeto')
    }

    if ($IncluirSegredos) {
        Copiar-Arquivo -De $claudeJson -ParaPasta $Destino
        $cred = Join-Path $origem '.credentials.json'
        if (Test-Path $cred) { Copiar-Arquivo -De $cred -ParaPasta $Destino }
        Show-Item -Texto 'credenciais de sessao' -Detalhe 'incluidas' -Estado 'aviso'
        Show-Aviso 'O pacote agora contem token OAuth e senhas em texto claro' @(
            'transporte apenas por canal criptografado'
        )
    } else {
        Show-Item -Texto 'credenciais de sessao' -Detalhe 'fora do pacote (-IncluirSegredos)' -Estado 'neutro'
    }
}

# --- 4. Os proprios scripts, para rodar o import de dentro do pacote ---
Show-Secao 'Ferramentas no pacote'
$copiados = 0
foreach ($script in @("exportar.ps1", "extrair.ps1", "importar.ps1", "verificar.ps1", "README.md", "GUIA.md")) {
    $caminho = Join-Path $PSScriptRoot $script
    if (Test-Path $caminho) {
        Copiar-Arquivo -De $caminho -ParaPasta $Destino
        $copiados++
    } else {
        Show-Item -Texto $script -Detalhe 'ausente: copie a mao para o pacote' -Estado 'aviso'
    }
}
Show-Item -Texto 'scripts e documentacao' -Detalhe (Format-Plural $copiados 'arquivo')

# a pasta lib/ acompanha: extrair.ps1, importar.ps1 e verificar.ps1 dependem dela
$libOrigem = Join-Path $PSScriptRoot "lib"
if (Test-Path $libOrigem) {
    Copiar-Arvore -De $libOrigem -Para (Join-Path $Destino "lib") -Mensagem "copiando lib"
    Show-Item -Texto 'lib' -Detalhe (Format-Plural (Get-ChildItem $libOrigem -File).Count 'helper')
} else {
    Show-Item -Texto 'lib' -Detalhe 'ausente: o pacote nao vai se verificar no destino' -Estado 'aviso'
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
Show-Item -Texto 'MANIFESTO.md' -Detalhe 'ficha da maquina de origem'

# --- 6. Inventario: o import usa para detectar transferencia incompleta ---
$helperInv = Join-Path $PSScriptRoot "lib\inventario.js"
if ((Test-Path $helperInv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $helperInv gerar $Destino
    if ($LASTEXITCODE -ne 0) { throw "falha ao gerar o inventario" }
} else {
    Show-Item -Texto 'INVENTARIO.txt' -Detalhe 'sem node: pacote sem verificacao' -Estado 'aviso'
}

$arquivosNoPacote = 0
$totalMb = $null
try {
    $medidaPacote = Get-ChildItem $Destino -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum
    $arquivosNoPacote = $medidaPacote.Count
    $totalMb = $medidaPacote.Sum / 1MB
} catch { }

# --- 7. Compactar e descartar a montagem ---
# O finally garante que a pasta de montagem nao sobrevive a uma falha do tar:
# ela carrega credenciais e conversas, e ficaria esquecida ao lado do destino.
Show-Secao 'Empacotando'
try {
    $null = Invoke-Externo -Programa "tar" -Mensagem "compactando o pacote" `
        -Argumentos @("-czf", $arquivoTgz, "-C", $Destino, ".")
} catch {
    Show-Erro 'falha ao compactar o pacote' @(
        "$_",
        'o destino esta acessivel, com espaco livre e sem o arquivo travado por outro processo?'
    )
    exit 1
} finally {
    if (Test-Path $Destino) { Remove-Item $Destino -Recurse -Force -ErrorAction SilentlyContinue }
}

# Le de volta o que acabou de ser escrito. A montagem ja foi descartada aqui, e o
# .tgz e a unica copia: um pacote ilegivel precisa ser detectado nesta maquina, e
# nao na outra, quando ja nao existe de onde gerar de novo.
$null = tar -tzf $arquivoTgz 2>&1
if ($LASTEXITCODE -ne 0) {
    Show-Erro 'o pacote gerado nao pode ser lido de volta' @(
        $arquivoTgz,
        'o arquivo ficou corrompido ou incompleto: rode o export de novo'
    )
    exit 1
}

$mbTgz = (Get-Item $arquivoTgz).Length / 1MB
$proporcao = if ($totalMb -gt 0) { ' ({0:N0}% do original)' -f (($mbTgz / $totalMb) * 100) } else { '' }
Show-Item -Texto ([IO.Path]::GetFileName($arquivoTgz)) -Detalhe (
    Join-Detalhe @((Format-Plural $arquivosNoPacote 'arquivo'), ('{0:N1} MB{1}' -f $mbTgz, $proporcao))
)
Show-Item -Texto 'pasta de montagem' -Detalhe 'removida' -Estado 'neutro'

# --- 8. Fechamento ---
Show-Resumo -Titulo 'Pacote pronto' -Campos ([ordered]@{
    'arquivo' = $arquivoTgz
    'tamanho' = '{0:N1} MB' -f $mbTgz
}) -Proximo @(
    'Leve este arquivo para a outra maquina e, na pasta deste projeto, rode:',
    ".\extrair.ps1 -Arquivo `"<caminho do .tgz la>`" -Destino `"<pasta onde extrair>`""
)

Show-Aviso 'Material sensivel' @(
    'o pacote contem credenciais de MCP e o conteudo das suas conversas',
    'apague o arquivo depois que o import do outro lado funcionar'
)
Write-Host ''
