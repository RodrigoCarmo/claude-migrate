<#
Volta o ambiente do Claude Code para um backup feito por um import anterior.

Uso:  .\restaurar.ps1                                           # lista, nao escreve nada
      .\restaurar.ps1 -Backup "$env:USERPROFILE\.claude.bkp.20260825-143000" -Simular
      .\restaurar.ps1 -Backup "$env:USERPROFILE\.claude.bkp.20260825-143000"

Sem -Backup nada e restaurado: escolher por voce qual ponto do passado vale
seria adivinhacao. Rodar sem parametro nenhum lista o que existe.

O backup escolhido e copiado, nunca movido, e o ambiente atual vira um backup
novo antes de qualquer escrita. Uma restauracao para o ponto errado tambem tem
volta, e o backup escolhido continua no lugar se algo falhar no meio.
#>
param(
    [string]$Backup,
    [switch]$Simular,
    [switch]$Forcar
)

$ErrorActionPreference = 'Stop'

# copia, estado e a camada visual
. (Join-Path $PSScriptRoot "lib\comum.ps1")
Initialize-Ui

$destinoClaude = Join-Path $env:USERPROFILE '.claude'
$destinoJson   = Join-Path $env:USERPROFILE '.claude.json'

Show-Cabecalho -Comando $(if ($Simular) { 'restaurar (simulacao)' } else { 'restaurar' }) `
    -Descricao 'devolve o ambiente ao estado de um backup anterior'

<#
A CLI do Claude Code roda dentro do node, e o app de desktop tem processo
proprio. Restaurar com qualquer um aberto perde a disputa: a aplicacao reescreve
arquivos em ~\.claude no meio da copia, e o resultado nao e nem o backup nem o
ambiente que estava aqui.
#>
function Get-ClaudeEmExecucao {
    $processos = @()
    $processos += @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue |
                    ForEach-Object { "claude (PID $($_.Id))" })
    try {
        $processos += @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
                        Where-Object { $_.CommandLine -and $_.CommandLine -match 'claude' } |
                        ForEach-Object { "node (PID $($_.ProcessId))" })
    } catch {
        # sem WMI nao ha como olhar a linha de comando: seguimos sem essa checagem
    }
    return @($processos | Sort-Object -Unique)
}

# --- 1. O que existe para restaurar ---
$disponiveis = Get-BackupsDisponiveis
if ($disponiveis.Count -eq 0) {
    Show-Erro 'nao ha backup neste perfil' @(
        "procurei por .claude.bkp* em $env:USERPROFILE",
        'o backup e criado pelo importar.ps1: sem import anterior, nao ha o que restaurar'
    )
    exit 1
}

# Sem escolha explicita este comando e apenas um catalogo. Restaurar o mais
# recente por conta propria seria o mesmo erro que apagar antes de conferir.
if (-not $Backup) {
    Show-Secao "Backups em $env:USERPROFILE"
    foreach ($item in $disponiveis) {
        $partes = @($item.Quando.ToString('dd/MM/yyyy HH:mm'), $item.Origem)
        # backup sem o .json de par ainda restaura a arvore, mas deixa a
        # configuracao de projetos e servidores MCP como esta hoje
        if (-not $item.Json) { $partes += 'sem o .claude.json de par' }
        Show-Item -Texto $item.Nome -Detalhe (Join-Detalhe $partes) `
            -Estado $(if ($item.Json) { 'ok' } else { 'aviso' })
    }
    Show-Resumo -Titulo (Format-Plural $disponiveis.Count 'backup disponivel' 'backups disponiveis') `
        -Estado 'info' -Proximo @(
        'Confira em -Simular antes de escrever:',
        ".\restaurar.ps1 -Backup ""$($disponiveis[0].Caminho)"" -Simular"
    )
    exit 0
}

# --- 2. A escolha e valida? ---
$Backup = [IO.Path]::GetFullPath($Backup)
$escolhido = @($disponiveis | Where-Object { $_.Caminho -eq $Backup })[0]
if (-not $escolhido) {
    Show-Erro 'esse caminho nao esta entre os backups deste perfil' @(
        $Backup,
        '',
        'rode sem parametro para ver a lista:',
        '.\restaurar.ps1'
    )
    exit 1
}

Show-Contexto ([ordered]@{
    'backup ' = $escolhido.Caminho
    'feito  ' = "$($escolhido.Quando.ToString('dd/MM/yyyy HH:mm'))   $($escolhido.Origem)"
    'destino' = $destinoClaude
})

# --- 3. Simulacao ---
# Vem antes da checagem de processo de proposito: simular nao escreve nada, e e
# exatamente o que se roda para decidir, com o Claude ainda aberto.
if ($Simular) {
    Show-Secao 'O que seria feito'
    $doBackup  = @(Get-ChildItem $escolhido.Caminho -Recurse -File -ErrorAction SilentlyContinue)
    $noDestino = @(Get-ChildItem $destinoClaude -Recurse -File -ErrorAction SilentlyContinue)
    Show-Item -Texto 'ambiente atual' -Estado 'info' `
        -Detalhe "$(Format-Plural $noDestino.Count 'arquivo') iriam para um backup novo"
    Show-Item -Texto '.claude' -Estado 'info' `
        -Detalhe "seria substituido por $(Format-Plural $doBackup.Count 'arquivo') do backup"
    Show-Item -Texto '.claude.json' -Estado $(if ($escolhido.Json) { 'info' } else { 'aviso' }) `
        -Detalhe $(if ($escolhido.Json) { 'voltaria com o do backup' } else { 'nao ha no backup: o atual ficaria' })
    Show-Resumo -Titulo 'Simulacao concluida, nada foi escrito' -Estado 'info' -Proximo @(
        'Se os numeros acima batem, aplique de verdade:',
        ".\restaurar.ps1 -Backup ""$($escolhido.Caminho)"""
    )
    exit 0
}

# --- 4. Nada de Claude aberto ---
$rodando = Get-ClaudeEmExecucao
if ($rodando.Count -gt 0) {
    if (-not $Forcar) {
        Show-Erro 'o Claude Code esta aberto' ($rodando + @(
            '',
            'feche a CLI e o app de desktop e rode de novo,',
            'ou passe -Forcar se tiver certeza de que nao e o Claude'
        ))
        exit 1
    }
    Show-Aviso '-Forcar: restaurando com processo do Claude aberto' -Detalhes $rodando
}

# --- 5. Guardar o que esta aqui agora ---
# Antes de qualquer escrita, e no mesmo formato dos outros backups: a volta da
# volta usa este mesmo script, sem procedimento especial.
Show-Secao 'Guardando o ambiente atual'
$carimbo = (Get-Date).ToString('yyyyMMdd-HHmmss')
$bkpAtual = $null
$bkpAtualJson = $null
if (Test-Path $destinoClaude) {
    $bkpAtual = Get-CaminhoLivre "$destinoClaude.bkp.$carimbo"
    Copiar-Arvore -De $destinoClaude -Para $bkpAtual -Mensagem 'guardando o ambiente atual'
    Show-Item -Texto '.claude' -Detalhe $bkpAtual
} else {
    Show-Item -Texto '.claude' -Detalhe 'nao havia ambiente aqui' -Estado 'neutro'
}
if (Test-Path $destinoJson) {
    $bkpAtualJson = Get-CaminhoLivre "$destinoJson.bkp.$carimbo"
    Copy-Item $destinoJson -Destination $bkpAtualJson
    Show-Item -Texto '.claude.json' -Detalhe $bkpAtualJson
}

# --- 6. Restaurar ---
Show-Secao 'Restaurando'
if (Test-Path $destinoClaude) {
    # -Force por causa dos .pack dos plugins, que chegam read-only. O ambiente
    # que esta sendo apagado acabou de ser copiado no passo anterior.
    Remove-Item $destinoClaude -Recurse -Force
}
Copiar-Arvore -De $escolhido.Caminho -Para $destinoClaude -Mensagem 'restaurando o ambiente'
Show-Item -Texto '.claude' -Detalhe "restaurado de $($escolhido.Nome)"

if ($escolhido.Json) {
    Copy-Item $escolhido.Json -Destination $destinoJson -Force
    Show-Item -Texto '.claude.json' -Detalhe "restaurado de $(Split-Path $escolhido.Json -Leaf)"
} else {
    Show-Item -Texto '.claude.json' -Detalhe 'nao havia no backup: o atual foi mantido' -Estado 'aviso'
}

# --- 7. Registrar ---
# O verificador le 'pacote' e 'importadoEm' para dizer de onde o ambiente veio.
# Depois de restaurar, a procedencia e o backup, e nao mais o ultimo import.
$agora = (Get-Date).ToString('o')
$null = Set-EstadoMigracao @{
    pacote      = $escolhido.Caminho
    importadoEm = $agora
    backups     = [ordered]@{ claude = $bkpAtual; claudeJson = $bkpAtualJson }
}
$null = Add-HistoricoMigracao ([ordered]@{
    acao             = 'restauracao'
    quando           = $agora
    de               = $escolhido.Caminho
    backupClaude     = $bkpAtual
    backupClaudeJson = $bkpAtualJson
})

Show-Resumo -Titulo 'Ambiente restaurado' -Campos ([ordered]@{
    'de'     = $escolhido.Nome
    'backup' = $(if ($bkpAtual) { $bkpAtual } else { 'nao havia ambiente anterior' })
}) -Proximo @(
    'claude   ->   /doctor, /mcp, /resume',
    'se voltou para o ponto errado, o ambiente de agora esta no backup acima'
)

$verificador = Join-Path $PSScriptRoot "verificar.ps1"
if (Test-Path $verificador) { & $verificador }
