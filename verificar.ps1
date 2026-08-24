<#
.SYNOPSIS
    Verifica se o ambiente Claude Code importado consegue rodar nesta maquina.

.DESCRIPTION
    Resolve toda referencia externa da configuracao (hooks, servidores MCP, plugins,
    skills, commands, permissoes) e responde uma pergunta: isto consegue rodar aqui?

    Nao executa nada de terceiros. Rodar hooks alheios tem efeito colateral real,
    entao a verificacao e estatica por decisao de seguranca.

    O relatorio separa quatro estados:
      resumo     o que existe e quanto esta pronto
      CORRIJA    impede o item de funcionar
      CONFIRME   sinalizado a partir do texto, pode ser falso positivo
      VALIDE     hooks que podem bloquear acoes, e so voce sabe se ainda decidem certo

.PARAMETER SemCor
    Desliga as cores ANSI da saida.

.EXAMPLE
    .\verificar.ps1
#>
param(
    [switch]$SemCor
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'node nao encontrado no PATH.' -ForegroundColor Red
    Write-Host 'O Claude Code instalado via npm ja traz o Node; instale-o antes de verificar.'
    exit 1
}

$analisador = Join-Path $PSScriptRoot 'lib\verificar.js'
if (-not (Test-Path $analisador)) {
    Write-Host "nao encontrei $analisador" -ForegroundColor Red
    exit 1
}

if ($SemCor) { $env:NO_COLOR = '1' }

node $analisador
exit $LASTEXITCODE
