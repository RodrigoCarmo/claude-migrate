<#
Extrai o pacote de migracao no PC novo, com diagnostico do que costuma dar errado.

Uso:  .\extrair.ps1
      .\extrair.ps1 -Arquivo 'D:\claude-backup.tgz' -Destino 'C:\Users\eu\claude-backup'

Sem parametros, procura claude-backup.tgz nos lugares obvios e extrai em
%USERPROFILE%\claude-backup.
#>
param(
    [string]$Arquivo,
    [string]$Destino = (Join-Path $env:USERPROFILE 'claude-backup'),
    [switch]$Limpar
)

$ErrorActionPreference = 'Stop'

# funcoes de copia e o indicador de progresso
. (Join-Path $PSScriptRoot "lib\comum.ps1")

# --- 1. Achar o arquivo ---
if (-not $Arquivo) {
    $candidatos = @(
        (Join-Path (Get-Location) 'claude-backup.tgz'),
        (Join-Path $env:USERPROFILE 'claude-backup.tgz'),
        (Join-Path $env:USERPROFILE 'Downloads\claude-backup.tgz'),
        (Join-Path $env:USERPROFILE 'Desktop\claude-backup.tgz'),
        (Join-Path $env:USERPROFILE 'OneDrive\claude-backup.tgz')
    ) | Where-Object { Test-Path $_ }

    if (-not $candidatos) {
        Write-Host 'Nao achei claude-backup.tgz. Procurei em:' -ForegroundColor Red
        Write-Host "  $(Get-Location)  (pasta atual)"
        Write-Host "  $env:USERPROFILE, Downloads, Desktop, OneDrive"
        Write-Host ''
        Write-Host 'Passe o caminho completo:' -ForegroundColor Yellow
        Write-Host "  .\extrair.ps1 -Arquivo 'D:\onde\estiver\claude-backup.tgz'"
        exit 1
    }
    $Arquivo = $candidatos[0]
    Write-Host "  achei: $Arquivo"
}

if (-not (Test-Path $Arquivo)) { Write-Host "nao existe: $Arquivo" -ForegroundColor Red; exit 1 }
# caminho absoluto de proposito: processo nativo nao herda o Set-Location do
# PowerShell, entao caminho relativo falha com "Failed to open" mesmo com o
# arquivo do lado. $item.FullName resolve isso para o tar.
$item = Get-Item $Arquivo

# --- 2. E um placeholder do OneDrive? ---
# Files On-Demand deixa o arquivo com tamanho logico certo mas sem conteudo local.
$RECALL_ON_DATA_ACCESS = 0x400000
$atributos = [int]$item.Attributes
if (($atributos -band $RECALL_ON_DATA_ACCESS) -or ($item.Attributes -band [IO.FileAttributes]::Offline)) {
    Write-Host '  ATENCAO: o arquivo e um placeholder do OneDrive (nao esta baixado)' -ForegroundColor Yellow
    Write-Host '  Clique com o botao direito > "Sempre manter neste dispositivo", espere baixar e rode de novo.' -ForegroundColor Yellow
    exit 1
}

# --- 3. Tamanho plausivel? ---
"  tamanho: {0:N1} MB" -f ($item.Length / 1MB) | Write-Host
if ($item.Length -lt 1MB) {
    Write-Host '  ATENCAO: arquivo pequeno demais. A transferencia provavelmente nao terminou.' -ForegroundColor Red
    exit 1
}

# --- 4. O tar consegue ler? ---
$null = tar -tzf $item.FullName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '  ATENCAO: o tar nao conseguiu ler o arquivo.' -ForegroundColor Red
    Write-Host '  Ou a transferencia corrompeu, ou foi enviado em modo texto. Transfira de novo em modo binario.' -ForegroundColor Red
    exit 1
}
Write-Host '  ok  arquivo integro'

# --- 5. Extrair ---
$Destino = [IO.Path]::GetFullPath($Destino)
if ((Test-Path $Destino) -and (Get-ChildItem $Destino -Force | Select-Object -First 1)) {
    Write-Host "  o destino ja tem conteudo: $Destino" -ForegroundColor Yellow
    Write-Host "  extrair por cima falha: os .pack do git sao read-only." -ForegroundColor Yellow
    if (-not $Limpar) {
        Write-Host "  rode de novo com -Limpar para apagar e extrair do zero," -ForegroundColor Yellow
        Write-Host "  ou passe -Destino apontando para uma pasta nova." -ForegroundColor Yellow
        exit 1
    }
    Remove-Item $Destino -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
try {
    $null = Invoke-Externo -Programa "tar" -Mensagem "extraindo o pacote" `
        -Argumentos @("-xzf", $item.FullName, "-C", $Destino)
} catch {
    Write-Host "  falha ao extrair: $_" -ForegroundColor Red
    exit 1
}
Write-Host "  ok  extraido em $Destino"

# --- 6. Tirar a marca de origem dos scripts ---
# Arquivo que atravessa uma transferencia chega marcado e a politica de execucao o recusa.
# Isso vale para os scripts deste projeto e, pior, para os hooks que serao importados:
# um hook que nao consegue iniciar nao bloqueia nada, e a acao que ele deveria impedir
# prossegue em silencio. Desbloquear aqui evita esse estado.
$marcados = Get-ChildItem $Destino -Recurse -File -Include *.ps1, *.js, *.psm1, *.sh, *.py -ErrorAction SilentlyContinue |
            Where-Object { Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
if ($marcados) {
    $marcados | Unblock-File
    Write-Host "  ok  marca de origem removida de $($marcados.Count) script(s)"
}

# --- 7. Conferir o inventario ---
$inv = Join-Path $Destino 'lib\inventario.js'
if ((Test-Path $inv) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    node $inv verificar $Destino
} else {
    Write-Host '  (sem node ainda: o import vai conferir o inventario depois)'
}

Write-Host ''
Write-Host 'Proximo passo:' -ForegroundColor Green
Write-Host "  cd '$Destino'"
Write-Host '  .\importar.ps1 -Pacote . -Simular'
