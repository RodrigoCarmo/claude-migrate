# Camada de apresentacao do CLI.
#
# Toda escrita em tela dos scripts passa por aqui. Os scripts dizem O QUE
# mostrar; este arquivo decide COMO, e e o unico lugar que conhece cores,
# glifos e largura de terminal.
#
# Duas capacidades sao detectadas, nunca assumidas:
#
#   Unicode  console em UTF-8 desenha as caixas e o spinner braille. Sem isso,
#            cada glifo cai para um equivalente ASCII. Um CLI bonito que vira
#            mojibake e pior que um CLI feio.
#   Cor      saida redirecionada (pipe, arquivo, CI) nao recebe cor, e NO_COLOR
#            desliga por vontade de quem chamou.
#
# As cores usam Write-Host -ForegroundColor, e nao sequencias ANSI cruas, porque
# funcionam identicamente no console legado, no Windows Terminal e no ISE.
#
# REGRA AO EDITAR ESTE PROJETO: nenhum caractere fora do ASCII escrito
# literalmente em arquivo .ps1. O PowerShell 5.1 le script sem BOM como ANSI, e
# um separador U+00B7 colado no codigo chega na tela como dois caracteres errados.
# Todo glifo nasce de um ponto de codigo aqui (Get-Glifo), pedido pelo nome.
# Este comentario e ASCII de proposito: ele descreve a regra que segue.

$script:Ui = @{
    Unicode  = $false
    Cor      = $true
    Largura  = 76
    Animavel = $true
    Inicio   = $null
}

function Initialize-Ui {
    # Pedir UTF-8 ao console e o que habilita os glifos. Falha em host que nao
    # deixa trocar a codificacao (ISE), e ai seguimos em ASCII.
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
        }
        $script:Ui.Unicode = ([Console]::OutputEncoding.CodePage -eq 65001)
    } catch {
        $script:Ui.Unicode = $false
    }

    $script:Ui.Cor = -not ($env:NO_COLOR -or [Console]::IsOutputRedirected)
    $script:Ui.Animavel = -not [Console]::IsOutputRedirected

    # Teto em 88: alem disso o detalhe alinhado a direita fica tao longe do
    # rotulo que o olho perde a associacao entre os dois.
    try {
        $largura = $Host.UI.RawUI.WindowSize.Width
        if ($largura -gt 0) { $script:Ui.Largura = [Math]::Max(56, [Math]::Min(88, $largura - 4)) }
    } catch { }

    $script:Ui.Inicio = Get-Date

    # Os helpers em Node escrevem no mesmo terminal. Publicar as capacidades no
    # ambiente faz todo processo filho desenhar igual, sem cada um redescobrir
    # por conta e errar (era o que trocava os glifos por ASCII no meio da lista).
    $env:CM_UNICODE = if ($script:Ui.Unicode) { '1' } else { '0' }
    $env:CM_LARGURA = [string]$script:Ui.Largura
}

<#
Concorda o substantivo com a quantidade: "1 arquivo", "2 arquivos".
#>
function Format-Plural {
    param(
        [Parameter(Mandatory)][int]$Quantidade,
        [Parameter(Mandatory)][string]$Singular,
        [string]$Plural
    )
    if (-not $Plural) { $Plural = $Singular + 's' }
    return "$Quantidade $(if ($Quantidade -eq 1) { $Singular } else { $Plural })"
}

<#
Tamanho legivel. Abaixo de 1 KB nao arredonda para "0 KB", que parece arquivo
vazio quando o arquivo so e pequeno.
#>
function Format-Tamanho {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    if ($Bytes -gt 0)   { return 'menos de 1 KB' }
    return 'vazio'
}

<#
Separador para compor detalhes: "3 arquivos <ponto> 4 KB". Existe para os
scripts nunca precisarem de um caractere nao-ASCII literal.
#>
function Join-Detalhe {
    param([Parameter(Mandatory)][string[]]$Partes)
    $visiveis = @($Partes | Where-Object { $_ })
    return ($visiveis -join "  $(Get-Glifo ponto)  ")
}

# ---------------------------------------------------------------------------
# Glifos
# ---------------------------------------------------------------------------

$script:GlifosUnicode = @{
    ok = [char]0x2713; erro = [char]0x2717; aviso = [char]0x26A0; info = [char]0x2139
    seta = [char]0x279C; ponto = [char]0x00B7; losango = [char]0x25C6; pendente = [char]0x25CB
    barraCheia = [char]0x2588; barraVazia = [char]0x2591; linha = [char]0x2500
    cantoSE = [char]0x250C; cantoSD = [char]0x2510; cantoIE = [char]0x2514; cantoID = [char]0x2518
    vertical = [char]0x2502; ramo = [char]0x251C; fim = [char]0x2514
}

$script:GlifosAscii = @{
    ok = '+'; erro = 'x'; aviso = '!'; info = 'i'
    seta = '>'; ponto = '-'; losango = '*'; pendente = 'o'
    barraCheia = '#'; barraVazia = '.'; linha = '-'
    cantoSE = '+'; cantoSD = '+'; cantoIE = '+'; cantoID = '+'
    vertical = '|'; ramo = '+'; fim = '\'
}

<#
O que este console aguenta. O verificar.ps1 repassa isto ao processo Node para
que os dois lados desenhem igual, em vez de cada um adivinhar por conta.
#>
function Get-CapacidadesUi {
    return [pscustomobject]@{
        Unicode  = $script:Ui.Unicode
        Cor      = $script:Ui.Cor
        Largura  = $script:Ui.Largura
        Animavel = $script:Ui.Animavel
    }
}

function Get-Glifo {
    param([Parameter(Mandatory)][string]$Nome)
    $tabela = if ($script:Ui.Unicode) { $script:GlifosUnicode } else { $script:GlifosAscii }
    return [string]$tabela[$Nome]
}

$script:QuadrosBraille = @(
    [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C,
    [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2807, [char]0x280F
)
$script:QuadrosAscii = @('|', '/', '-', '\')

function Get-QuadrosSpinner {
    if ($script:Ui.Unicode) { return $script:QuadrosBraille }
    return $script:QuadrosAscii
}

# ---------------------------------------------------------------------------
# Primitivas
# ---------------------------------------------------------------------------

function Write-Cor {
    param(
        [string]$Texto = '',
        [string]$Cor = 'Gray',
        [switch]$SemQuebra
    )
    $argumentos = @{ Object = $Texto; NoNewline = [bool]$SemQuebra }
    if ($script:Ui.Cor) { $argumentos.ForegroundColor = $Cor }
    Write-Host @argumentos
}

function Write-Linha { Write-Host '' }

# ---------------------------------------------------------------------------
# Componentes
# ---------------------------------------------------------------------------

<#
Assinatura do comando. Abre toda execucao, para que uma tela rolada continue
dizendo de que ferramenta ela e.
#>
function Show-Cabecalho {
    param(
        [Parameter(Mandatory)][string]$Comando,
        [string]$Descricao
    )
    Write-Linha
    Write-Cor "  $(Get-Glifo losango) " 'Magenta' -SemQuebra
    Write-Cor 'claude-migrate' 'White' -SemQuebra
    Write-Cor "  $(Get-Glifo ponto)  " 'DarkGray' -SemQuebra
    Write-Cor $Comando 'Magenta'
    if ($Descricao) {
        Write-Cor "     $Descricao" 'DarkGray'
    }
    Write-Linha
}

<#
Os caminhos que este comando vai ler e escrever, antes de tocar em qualquer
coisa. E a resposta visivel para "de onde para onde", e por isso vem sempre no
topo, nao no fim.
#>
function Show-Contexto {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Campos)

    $larguraRotulo = 0
    foreach ($chave in $Campos.Keys) {
        if ($chave.Length -gt $larguraRotulo) { $larguraRotulo = $chave.Length }
    }
    foreach ($chave in $Campos.Keys) {
        $rotulo = $chave.PadRight($larguraRotulo)
        Write-Cor "  $rotulo  " 'DarkGray' -SemQuebra
        Write-Cor ([string]$Campos[$chave]) 'Cyan'
    }
    Write-Linha
}

function Show-Divisor {
    $linha = [string](Get-Glifo linha) * $script:Ui.Largura
    Write-Cor "  $linha" 'DarkGray'
}

<#
Titulo de etapa. Separa blocos longos de itens sem custar uma linha em branco
a cada dois itens.
#>
function Show-Secao {
    param([Parameter(Mandatory)][string]$Titulo)
    Write-Linha
    Write-Cor "  $Titulo" 'White'
}

$script:EstilosItem = @{
    ok       = @{ Glifo = 'ok';       Cor = 'Green'    }
    erro     = @{ Glifo = 'erro';     Cor = 'Red'      }
    aviso    = @{ Glifo = 'aviso';    Cor = 'Yellow'   }
    info     = @{ Glifo = 'info';     Cor = 'Cyan'     }
    pendente = @{ Glifo = 'pendente'; Cor = 'DarkGray' }
    neutro   = @{ Glifo = 'ponto';    Cor = 'DarkGray' }
}

<#
Uma linha de resultado, com o detalhe alinhado a direita. O alinhamento e o que
transforma uma lista de frases numa tabela legivel de relance.
#>
function Show-Item {
    param(
        [Parameter(Mandatory)][string]$Texto,
        [string]$Detalhe,
        [ValidateSet('ok', 'erro', 'aviso', 'info', 'pendente', 'neutro')][string]$Estado = 'ok',
        [int]$Recuo = 0
    )
    $estilo = $script:EstilosItem[$Estado]
    $espaco = ' ' * $Recuo

    Write-Cor "  $espaco$(Get-Glifo $estilo.Glifo) " $estilo.Cor -SemQuebra
    Write-Cor $Texto 'Gray' -SemQuebra

    if ($Detalhe) {
        # 4 = dois espacos de recuo + glifo + espaco
        $usado = 4 + $Recuo + $Texto.Length
        $preenchimento = $script:Ui.Largura - $usado - $Detalhe.Length
        if ($preenchimento -lt 1) { $preenchimento = 1 }
        Write-Cor (' ' * $preenchimento) 'DarkGray' -SemQuebra
        Write-Cor $Detalhe 'DarkGray'
    } else {
        Write-Linha
    }
}

function Show-Nota {
    param([Parameter(Mandatory)][string]$Texto, [int]$Recuo = 4)
    Write-Cor ((' ' * ($Recuo + 2)) + $Texto) 'DarkGray'
}

function Show-Aviso {
    param([Parameter(Mandatory)][string]$Texto, [string[]]$Detalhes)
    Write-Linha
    Write-Cor "  $(Get-Glifo aviso)  " 'Yellow' -SemQuebra
    Write-Cor $Texto 'Yellow'
    foreach ($detalhe in $Detalhes) { Write-Cor "     $detalhe" 'DarkGray' }
}

function Show-Erro {
    param([Parameter(Mandatory)][string]$Texto, [string[]]$Detalhes)
    Write-Linha
    Write-Cor "  $(Get-Glifo erro)  " 'Red' -SemQuebra
    Write-Cor $Texto 'Red'
    foreach ($detalhe in $Detalhes) { Write-Cor "     $detalhe" 'DarkGray' }
}

<#
Barra de progresso para laco proprio, onde nao ha processo externo para observar.
#>
function Show-Barra {
    param(
        [Parameter(Mandatory)][int]$Atual,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Mensagem,
        [int]$Comprimento = 24
    )
    if (-not $script:Ui.Animavel -or $Total -le 0) { return }

    $fracao = [Math]::Min(1.0, $Atual / $Total)
    $cheias = [int][Math]::Round($fracao * $Comprimento)
    $barra = ([string](Get-Glifo barraCheia) * $cheias) +
             ([string](Get-Glifo barraVazia) * ($Comprimento - $cheias))
    $percentual = '{0,3:N0}%' -f ($fracao * 100)

    Write-Host "`r" -NoNewline
    Write-Cor '  ' 'Gray' -SemQuebra
    Write-Cor $barra 'Magenta' -SemQuebra
    Write-Cor "  $percentual  " 'White' -SemQuebra
    Write-Cor "$Mensagem  ($Atual/$Total)" 'DarkGray' -SemQuebra
}

function Complete-Barra {
    if (-not $script:Ui.Animavel) { return }
    Write-Host ("`r" + (' ' * ($script:Ui.Largura + 4)) + "`r") -NoNewline
}

<#
Um quadro do spinner. Copiar plugins ou compactar leva dezenas de segundos sem
escrever nada: sem sinal de atividade a impressao e de travamento.
O tempo so aparece depois de 3s, senao o numero apenas pisca.
#>
function Write-Girando {
    param(
        [Parameter(Mandatory)][int]$Indice,
        [Parameter(Mandatory)][string]$Mensagem,
        [int]$Segundos = 0
    )
    if (-not $script:Ui.Animavel) { return }

    $quadros = Get-QuadrosSpinner
    Write-Host "`r" -NoNewline
    Write-Cor "  $($quadros[$Indice % $quadros.Count])  " 'Magenta' -SemQuebra
    Write-Cor $Mensagem 'Gray' -SemQuebra
    if ($Segundos -ge 3) { Write-Cor "  ${Segundos}s" 'DarkGray' -SemQuebra }
    Write-Host '    ' -NoNewline
}

function Complete-Girando {
    if (-not $script:Ui.Animavel) { return }
    Write-Host ("`r" + (' ' * ($script:Ui.Largura + 8)) + "`r") -NoNewline
}

<#
Fecha a execucao: o que foi produzido e para onde ir em seguida. O tempo total
sai daqui porque quem esperou merece saber quanto esperou.
#>
function Show-Resumo {
    param(
        [Parameter(Mandatory)][string]$Titulo,
        [System.Collections.IDictionary]$Campos,
        [string[]]$Proximo,
        [ValidateSet('ok', 'erro', 'aviso', 'info', 'neutro')][string]$Estado = 'ok'
    )
    $estilo = $script:EstilosItem[$Estado]

    Write-Linha
    Show-Divisor
    Write-Linha

    Write-Cor "  $(Get-Glifo $estilo.Glifo)  " $estilo.Cor -SemQuebra
    Write-Cor $Titulo 'White' -SemQuebra
    if ($script:Ui.Inicio) {
        $segundos = ((Get-Date) - $script:Ui.Inicio).TotalSeconds
        $tempo = if ($segundos -ge 60) { '{0:N0}m {1:N0}s' -f [Math]::Floor($segundos / 60), ($segundos % 60) }
                 else { '{0:N1}s' -f $segundos }
        Write-Cor "   em $tempo" 'DarkGray'
    } else {
        Write-Linha
    }

    if ($Campos -and $Campos.Count -gt 0) {
        Write-Linha
        $larguraRotulo = 0
        foreach ($chave in $Campos.Keys) {
            if ($chave.Length -gt $larguraRotulo) { $larguraRotulo = $chave.Length }
        }
        foreach ($chave in $Campos.Keys) {
            Write-Cor "     $($chave.PadRight($larguraRotulo))  " 'DarkGray' -SemQuebra
            Write-Cor ([string]$Campos[$chave]) 'Gray'
        }
    }

    if ($Proximo -and $Proximo.Count -gt 0) {
        Write-Linha
        Write-Cor "  $(Get-Glifo seta)  " 'Cyan' -SemQuebra
        Write-Cor 'Proximo passo' 'Cyan'
        foreach ($comando in $Proximo) {
            Write-Cor "     $comando" 'White'
        }
    }
    Write-Linha
}
