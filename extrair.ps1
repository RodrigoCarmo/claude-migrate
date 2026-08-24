<#
Extrai o pacote de migracao no PC novo, com diagnostico do que costuma dar errado.

Uso:  .\extrair.ps1 -Arquivo "$env:USERPROFILE\Downloads\claude-backup.tgz" -Destino "D:\claude-restore"
      .\extrair.ps1 -Arquivo "...\claude-backup.tgz" -Destino "D:\claude-restore" -Limpar

Os dois caminhos sao obrigatorios de proposito: voce diz de onde ler e onde
escrever, e ambos ficam visiveis no comando digitado.

Antes de extrair confere se o arquivo chegou inteiro, se nao e um placeholder do
OneDrive e se o tar consegue abrir. Depois tira a marca de origem dos scripts,
que de outro modo faria os hooks importados falharem em silencio.
#>
param(
    [Parameter(Mandatory)][string]$Arquivo,
    [Parameter(Mandatory)][string]$Destino,
    [switch]$Limpar
)

$ErrorActionPreference = 'Stop'

# copia, execucao externa e a camada visual
. (Join-Path $PSScriptRoot "lib\comum.ps1")
Initialize-Ui

Show-Cabecalho -Comando 'extrair' -Descricao 'abre o pacote no lugar que voce escolheu'

if (-not (Test-Path $Arquivo)) {
    Show-Erro 'o arquivo informado nao existe' @($Arquivo)
    exit 1
}
# caminho absoluto de proposito: processo nativo nao herda o Set-Location do
# PowerShell, entao caminho relativo falha com "Failed to open" mesmo com o
# arquivo do lado. $item.FullName resolve isso para o tar.
$item = Get-Item $Arquivo
$Destino = [IO.Path]::GetFullPath($Destino)

Show-Contexto ([ordered]@{
    'arquivo' = $item.FullName
    'destino' = $Destino
})

# Extrair sobre a pasta do proprio projeto sobrescreveria os scripts em uso.
if ($Destino -eq [IO.Path]::GetFullPath($PSScriptRoot)) {
    Show-Erro 'o destino e a pasta deste projeto' @('escolha outro lugar para extrair')
    exit 1
}

Show-Secao 'Conferindo o arquivo'

# --- 1. E um placeholder do OneDrive? ---
# Files On-Demand deixa o arquivo com tamanho logico certo mas sem conteudo local.
$RECALL_ON_DATA_ACCESS = 0x400000
$atributos = [int]$item.Attributes
if (($atributos -band $RECALL_ON_DATA_ACCESS) -or ($item.Attributes -band [IO.FileAttributes]::Offline)) {
    Show-Item -Texto 'conteudo local' -Detalhe 'placeholder do OneDrive' -Estado 'erro'
    Show-Erro 'o arquivo nao esta baixado nesta maquina' @(
        'botao direito no .tgz > "Sempre manter neste dispositivo"',
        'espere baixar e rode de novo'
    )
    exit 1
}
Show-Item -Texto 'conteudo local' -Detalhe 'baixado'

# --- 2. Tamanho plausivel? ---
$mb = $item.Length / 1MB
if ($item.Length -lt 1MB) {
    Show-Item -Texto 'tamanho' -Detalhe ('{0:N1} MB' -f $mb) -Estado 'erro'
    Show-Erro 'arquivo pequeno demais' @('a transferencia provavelmente nao terminou: copie de novo')
    exit 1
}
Show-Item -Texto 'tamanho' -Detalhe ('{0:N1} MB' -f $mb)

# --- 3. O tar consegue ler? ---
$null = tar -tzf $item.FullName 2>&1
if ($LASTEXITCODE -ne 0) {
    Show-Item -Texto 'leitura pelo tar' -Detalhe 'falhou' -Estado 'erro'
    Show-Erro 'o tar nao conseguiu abrir o arquivo' @(
        'ou a transferencia corrompeu, ou foi enviada em modo texto',
        'transfira de novo em modo binario'
    )
    exit 1
}
Show-Item -Texto 'leitura pelo tar' -Detalhe 'integro'

# --- 4. Destino ocupado ---
# Extrair por cima falha no meio: os .pack dos plugins sao read-only.
if ((Test-Path $Destino) -and (Get-ChildItem $Destino -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    if (-not $Limpar) {
        Show-Item -Texto 'destino' -Detalhe 'ja tem conteudo' -Estado 'erro'
        Show-Erro "a pasta de destino nao esta vazia" @(
            $Destino,
            'extrair por cima falha: os .pack dos plugins sao read-only',
            '',
            'rode de novo com -Limpar para apagar e extrair do zero,',
            'ou passe -Destino apontando para uma pasta nova'
        )
        exit 1
    }
    Show-Item -Texto 'destino' -Detalhe '-Limpar: apagando o conteudo anterior' -Estado 'aviso'
    Remove-Item $Destino -Recurse -Force
}

# --- 5. Extrair ---
Show-Secao 'Extraindo'
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
try {
    $null = Invoke-Externo -Programa "tar" -Mensagem "extraindo o pacote" `
        -Argumentos @("-xzf", $item.FullName, "-C", $Destino)
} catch {
    Show-Erro 'falha ao extrair' @("$_")
    exit 1
}
$totalArquivos = 0
try { $totalArquivos = (Get-ChildItem $Destino -Recurse -File -ErrorAction SilentlyContinue).Count } catch { }
Show-Item -Texto 'pacote aberto' -Detalhe (Format-Plural $totalArquivos 'arquivo')

# --- 6. Tirar a marca de origem dos scripts ---
# Arquivo que atravessa uma transferencia chega marcado e a politica de execucao o recusa.
# Isso vale para os scripts deste projeto e, pior, para os hooks que serao importados:
# um hook que nao consegue iniciar nao bloqueia nada, e a acao que ele deveria impedir
# prossegue em silencio. Desbloquear aqui evita esse estado.
$marcados = Get-ChildItem $Destino -Recurse -File -Include *.ps1, *.js, *.psm1, *.sh, *.py -ErrorAction SilentlyContinue |
            Where-Object { Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
if ($marcados) {
    $marcados | Unblock-File
    Show-Item -Texto 'marca de origem' -Detalhe ('removida de ' + (Format-Plural $marcados.Count 'script'))
} else {
    Show-Item -Texto 'marca de origem' -Detalhe 'nenhum script marcado'
}

# --- 7. Conferir o inventario ---
$inv = Join-Path $Destino 'lib\inventario.js'
if ((Test-Path $inv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $inv verificar $Destino
} else {
    Show-Item -Texto 'integridade' -Detalhe 'sem node ainda: o import confere depois' -Estado 'neutro'
}

# --- 8. Registrar o que foi feito ---
# Nao substitui os parametros do proximo passo: serve de trilha para o
# verificar.ps1 dizer de onde veio o ambiente, e para saber o que desfazer.
$null = Set-EstadoMigracao @{
    pacote      = $Destino
    tgzOrigem   = $item.FullName
    extraidoEm  = (Get-Date).ToString('o')
    importadoEm = $null
}

Show-Resumo -Titulo 'Pacote extraido' -Campos ([ordered]@{
    'pasta'    = $Destino
    'arquivos' = "$totalArquivos"
}) -Proximo @(
    "cd `"$Destino`"",
    ".\importar.ps1 -Pacote `"$Destino`" -Simular"
)
