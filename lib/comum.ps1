# Funcoes compartilhadas pelos scripts: copia, execucao de processo externo e o
# indicador de progresso.
#
# Operacoes como copiar a arvore de plugins ou compactar o pacote levam dezenas de
# segundos sem escrever nada na tela. Sem sinal de atividade, a impressao e de travamento.

# robocopy e tar aguentam caminho longo (>260 chars), ao contrario de Copy-Item.
# Sao processos externos, entao da para acompanhar o progresso enquanto rodam.

$script:QuadrosSpinner = @('|', '/', '-', '\')

function Test-Animavel {
    # Saida redirecionada (pipe, arquivo, CI) nao suporta reescrever a linha:
    # animar ali produz lixo em vez de spinner.
    return -not [Console]::IsOutputRedirected
}

function Write-Etapa {
    param([string]$Texto)
    Write-Host "  ok  $Texto"
}

<#
Executa um programa externo mostrando atividade enquanto ele roda.
Devolve a saida combinada; lanca se o codigo de saida passar de $ExitAceitavel.
#>
function Invoke-Externo {
    param(
        [Parameter(Mandatory)][string]$Programa,
        [Parameter(Mandatory)][string[]]$Argumentos,
        [Parameter(Mandatory)][string]$Mensagem,
        [int]$ExitAceitavel = 0
    )

    $saidaTmp = [IO.Path]::GetTempFileName()
    $erroTmp = [IO.Path]::GetTempFileName()

    # Start-Process junta os argumentos numa unica linha de comando: sem aspas, um caminho
    # com espaco vira dois argumentos e o programa opera no alvo errado, em silencio.
    # A barra final precisa ser dobrada, senao escapa a aspa de fechamento.
    $argumentosEscapados = foreach ($argumento in $Argumentos) {
        if ($argumento -match '[\s"]') {
            '"' + ($argumento -replace '(\\*)$', '$1$1') + '"'
        } else {
            $argumento
        }
    }

    try {
        $processo = Start-Process -FilePath $Programa -ArgumentList $argumentosEscapados `
            -NoNewWindow -PassThru -RedirectStandardOutput $saidaTmp -RedirectStandardError $erroTmp

        if (Test-Animavel) {
            $indice = 0
            $inicio = Get-Date
            while (-not $processo.HasExited) {
                $quadro = $script:QuadrosSpinner[$indice % $script:QuadrosSpinner.Count]
                $segundos = [int]((Get-Date) - $inicio).TotalSeconds
                # so mostra o tempo depois de 3s: em operacao rapida o numero so pisca
                $tempo = if ($segundos -ge 3) { "  ${segundos}s" } else { '' }
                Write-Host "`r  $quadro  $Mensagem$tempo" -NoNewline
                Start-Sleep -Milliseconds 120
                $indice++
            }
            # limpa a linha do spinner antes de quem chamou escrever o resultado
            Write-Host ("`r" + (' ' * ($Mensagem.Length + 24)) + "`r") -NoNewline
        }
        else {
            Write-Host "  ... $Mensagem"
            $processo.WaitForExit()
        }

        $saida = @()
        if (Test-Path $saidaTmp) { $saida += Get-Content $saidaTmp -ErrorAction SilentlyContinue }
        if (Test-Path $erroTmp) { $saida += Get-Content $erroTmp -ErrorAction SilentlyContinue }

        if ($processo.ExitCode -gt $ExitAceitavel) {
            throw "$Programa falhou (codigo $($processo.ExitCode))`n$($saida -join "`n")"
        }
        return $saida
    }
    finally {
        Remove-Item $saidaTmp, $erroTmp -Force -ErrorAction SilentlyContinue
    }
}

function Copiar-Arvore {
    param(
        [Parameter(Mandatory)][string]$De,
        [Parameter(Mandatory)][string]$Para,
        [string]$Mensagem
    )
    if (-not $Mensagem) { $Mensagem = "copiando $(Split-Path $De -Leaf)" }
    # robocopy usa 0-7 para sucesso e 8+ para erro real
    $null = Invoke-Externo -Programa 'robocopy' -Mensagem $Mensagem -ExitAceitavel 7 `
        -Argumentos @($De, $Para, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    $global:LASTEXITCODE = 0
}

function Copiar-Arquivo {
    param(
        [Parameter(Mandatory)][string]$De,
        [Parameter(Mandatory)][string]$ParaPasta
    )
    # arquivo unico e instantaneo: spinner aqui so pisca e atrapalha
    $saida = robocopy (Split-Path $De -Parent) $ParaPasta (Split-Path $De -Leaf) /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE) em $De`n$saida" }
    $global:LASTEXITCODE = 0
}

<#
Progresso para laços do proprio PowerShell, onde nao ha processo externo para observar.
Chame Write-Passo a cada item e Complete-Passo no fim.
#>
function Write-Passo {
    param(
        [Parameter(Mandatory)][int]$Atual,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Mensagem
    )
    if (-not (Test-Animavel)) { return }
    $quadro = $script:QuadrosSpinner[$Atual % $script:QuadrosSpinner.Count]
    Write-Host "`r  $quadro  $Mensagem ($Atual/$Total)" -NoNewline
}

function Complete-Passo {
    param([int]$Largura = 70)
    if (-not (Test-Animavel)) { return }
    Write-Host ("`r" + (' ' * $Largura) + "`r") -NoNewline
}
