<#
.SYNOPSIS
    Verifica se o ambiente Claude Code importado consegue rodar nesta maquina.

.DESCRIPTION
    Resolve toda referencia externa da configuracao (hooks, servidores MCP, plugins,
    skills, commands, permissoes) e responde uma pergunta: isto consegue rodar aqui?

    Nao executa nada de terceiros. Rodar hooks alheios tem efeito colateral real,
    entao a verificacao e estatica por decisao de seguranca.

    O relatorio separa quatro estados:
      Inventario   o que existe e quanto esta pronto
      CORRIJA      impede o item de funcionar
      CONFIRME     sinalizado a partir do texto, pode ser falso positivo
      VALIDE       hooks que podem bloquear acoes, e so voce sabe se decidem certo

.PARAMETER SemCor
    Desliga as cores da saida.

.EXAMPLE
    .\verificar.ps1
#>
param(
    [switch]$SemCor
)

$ErrorActionPreference = 'Stop'

# A analise vive em lib\verificar.js; aqui so preparamos o terreno para ela.
$comum = Join-Path $PSScriptRoot 'lib\comum.ps1'
if (Test-Path $comum) { . $comum; Initialize-Ui }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    if (Get-Command Show-Erro -ErrorAction SilentlyContinue) {
        Show-Erro 'node nao encontrado no PATH' @(
            'o Claude Code instalado via npm ja traz o Node',
            'instale-o antes de verificar'
        )
    } else {
        Write-Host 'node nao encontrado no PATH.' -ForegroundColor Red
    }
    exit 1
}

$analisador = Join-Path $PSScriptRoot 'lib\verificar.js'
if (-not (Test-Path $analisador)) {
    Write-Host "nao encontrei $analisador" -ForegroundColor Red
    exit 1
}

if ($SemCor) { $env:NO_COLOR = '1' }

# CM_UNICODE e CM_LARGURA ja foram publicados no ambiente pelo Initialize-Ui, e
# o processo Node os herda: nao ha o que repassar aqui.

# De onde veio este ambiente, quando o extrair/importar registraram.
if (Get-Command Get-EstadoMigracao -ErrorAction SilentlyContinue) {
    $estado = Get-EstadoMigracao
    if ($estado -and $estado.importadoEm) {
        $quando = try { ([datetime]$estado.importadoEm).ToString('dd/MM/yyyy HH:mm') } catch { $estado.importadoEm }
        $env:CM_ORIGEM = "$($estado.pacote)   em $quando"
    }
}

try {
    node $analisador
    $codigo = $LASTEXITCODE
} finally {
    Remove-Item Env:\CM_UNICODE, Env:\CM_LARGURA, Env:\CM_ORIGEM -ErrorAction SilentlyContinue
}

exit $codigo
