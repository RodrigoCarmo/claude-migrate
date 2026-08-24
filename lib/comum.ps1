# Funcoes compartilhadas pelos scripts: copia, execucao de processo externo e o
# indicador de progresso.
#
# Operacoes como copiar a arvore de plugins ou compactar o pacote levam dezenas de
# segundos sem escrever nada na tela. Sem sinal de atividade, a impressao e de travamento.

# robocopy e tar aguentam caminho longo (>260 chars), ao contrario de Copy-Item.
# Sao processos externos, entao da para acompanhar o progresso enquanto rodam.

# A apresentacao vive em ui.ps1: aqui ficam so copia e execucao.
. (Join-Path $PSScriptRoot "ui.ps1")

function Test-Animavel {
    # Saida redirecionada (pipe, arquivo, CI) nao suporta reescrever a linha:
    # animar ali produz lixo em vez de spinner.
    return -not [Console]::IsOutputRedirected
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

        # Ler .Handle aqui e obrigatorio, nao decorativo: sem isso o .NET descarta
        # o handle do processo ao termino e $processo.ExitCode volta VAZIO, mesmo
        # com HasExited = True. Como $null -gt 0 e falso, a checagem de erro no fim
        # desta funcao nunca disparava e uma falha de tar ou robocopy passava por
        # sucesso (um tar que nao conseguiu escrever chegou a ser anunciado como
        # "pacote pronto", com 0 MB).
        $null = $processo.Handle

        if (Test-Animavel) {
            $indice = 0
            $inicio = Get-Date
            while (-not $processo.HasExited) {
                Write-Girando -Indice $indice -Mensagem $Mensagem `
                    -Segundos ([int]((Get-Date) - $inicio).TotalSeconds)
                Start-Sleep -Milliseconds 100
                $indice++
            }
            # limpa a linha do spinner antes de quem chamou escrever o resultado
            Complete-Girando
        }
        else {
            # sem animacao possivel, quem chamou anuncia o resultado depois
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

# Progresso de laco proprio, sem processo externo para observar: Show-Barra em
# ui.ps1. Aqui ficam apenas copia e execucao.

# ---------------------------------------------------------------------------
# Estado da migracao
#
# Os scripts rodam em sessoes de terminal diferentes e precisam saber o que o
# anterior fez. Sem isso, cada passo pede de novo um caminho que o usuario ja
# digitou, e o fluxo so existe na cabeca dele.
#
# A ancora primaria e $PSScriptRoot: importar.ps1 e verificar.ps1 sao copiados
# para dentro do pacote, entao a propria localizacao deles ja responde "onde
# esta o pacote". O arquivo de estado cobre o resto: rodar de outro diretorio,
# saber qual .tgz deu origem a isto, e onde ficaram os backups.
# ---------------------------------------------------------------------------

function Get-CaminhoEstado {
    return (Join-Path $env:USERPROFILE '.claude-migrate.json')
}

function Get-EstadoMigracao {
    $caminho = Get-CaminhoEstado
    if (-not (Test-Path $caminho)) { return $null }
    try {
        return (Get-Content $caminho -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        # estado corrompido nao pode derrubar a migracao: seguimos sem ele
        Write-Warning "estado ilegivel em $caminho, ignorando"
        return $null
    }
}

<#
Grava campos no estado, preservando o que ja estava la.
Devolve o caminho do arquivo.
#>
function Set-EstadoMigracao {
    param([Parameter(Mandatory)][hashtable]$Campos)

    # [ordered] de proposito: hashtable comum embaralha as chaves a cada gravacao,
    # e o arquivo e para ser lido por gente quando algo der errado.
    $estado = [ordered]@{ versao = 1 }
    $atual = Get-EstadoMigracao
    if ($atual) {
        foreach ($prop in $atual.PSObject.Properties) { $estado[$prop.Name] = $prop.Value }
    }
    foreach ($par in $Campos.GetEnumerator()) { $estado[$par.Key] = $par.Value }
    $estado['versao'] = 1

    $caminho = Get-CaminhoEstado
    [IO.File]::WriteAllText($caminho, ($estado | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    return $caminho
}

function Remove-EstadoMigracao {
    $caminho = Get-CaminhoEstado
    if (Test-Path $caminho) { Remove-Item $caminho -Force }
}

<#
Uma pasta so conta como pacote se tem a arvore .claude e a assinatura que o
exportar.ps1 deixa. Sem essa checagem, apontar para a pasta errada so falharia
la na frente, no meio da copia.
#>
function Test-EhPacote {
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $false }
    if (-not (Test-Path $Caminho)) { return $false }
    if (-not (Test-Path (Join-Path $Caminho '.claude'))) { return $false }
    return ((Test-Path (Join-Path $Caminho 'MANIFESTO.md')) -or
            (Test-Path (Join-Path $Caminho 'INVENTARIO.txt')))
}

<#
Onde esta o pacote, em ordem de confianca:
  1. o que veio na linha de comando
  2. a pasta do proprio script, que dentro do pacote extraido e o pacote
  3. o que o extrair.ps1 anotou no estado
Devolve $null se nada resolver, para quem chamou decidir a mensagem.
#>
function Resolve-Pacote {
    param(
        [string]$Informado,
        [Parameter(Mandatory)][string]$Raiz
    )

    if (-not [string]::IsNullOrWhiteSpace($Informado)) {
        $absoluto = [IO.Path]::GetFullPath($Informado)
        if (-not (Test-EhPacote $absoluto)) {
            throw "nao parece um pacote de migracao: $absoluto`n  esperava encontrar .claude\ e MANIFESTO.md ali dentro"
        }
        return $absoluto
    }

    if (Test-EhPacote $Raiz) { return [IO.Path]::GetFullPath($Raiz) }

    $estado = Get-EstadoMigracao
    if ($estado -and (Test-EhPacote $estado.pacote)) {
        Write-Host "  pacote: $($estado.pacote)"
        Write-Host "          (anotado pelo extrair.ps1 em $(Get-CaminhoEstado))"
        return [IO.Path]::GetFullPath($estado.pacote)
    }

    return $null
}

# ---------------------------------------------------------------------------
# Perguntas
# ---------------------------------------------------------------------------

<#
Read-Host sem stdin (CI, pipe, processo redirecionado) devolve vazio em loop.
Nesses casos o default silencioso e a unica saida sa.
#>
function Test-Interativo {
    if ([Console]::IsInputRedirected) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    return $true
}

<#
Pergunta com default. Enter aceita o default; terminal nao interativo usa o
default e diz que usou, em vez de travar esperando alguem que nao esta la.
#>
function Read-Resposta {
    param(
        [Parameter(Mandatory)][string]$Pergunta,
        [string]$Padrao,
        [string[]]$Notas
    )

    if (-not (Test-Interativo)) {
        Write-Host "  $Pergunta"
        Write-Host "  (terminal nao interativo, usando: $Padrao)"
        return $Padrao
    }

    Write-Host ''
    Write-Host "  $Pergunta" -ForegroundColor Cyan
    foreach ($nota in $Notas) { Write-Host "    $nota" -ForegroundColor DarkGray }
    if ($Padrao) { Write-Host "    [Enter] usa $Padrao" -ForegroundColor DarkGray }
    $resposta = Read-Host '  >'

    if ([string]::IsNullOrWhiteSpace($resposta)) { return $Padrao }
    # caminho colado do Explorer costuma vir com aspas
    return $resposta.Trim().Trim('"').Trim("'")
}

function Read-Confirmacao {
    param(
        [Parameter(Mandatory)][string]$Pergunta,
        [switch]$PadraoSim
    )
    $dica = if ($PadraoSim) { '[S/n]' } else { '[s/N]' }
    if (-not (Test-Interativo)) {
        Write-Host "  $Pergunta $dica  (nao interativo: $(if ($PadraoSim) { 'sim' } else { 'nao' }))"
        return [bool]$PadraoSim
    }
    Write-Host ''
    $resposta = Read-Host "  $Pergunta $dica"
    if ([string]::IsNullOrWhiteSpace($resposta)) { return [bool]$PadraoSim }
    return $resposta.Trim() -match '^(s|sim|y|yes)$'
}

<#
Primeiro nome livre a partir do sugerido: claude-restore, claude-restore-2, ...
Evita a colisao de destino em vez de so reclamar dela.
#>
function Get-CaminhoLivre {
    param([Parameter(Mandatory)][string]$Sugestao)
    if (-not (Test-Path $Sugestao)) { return $Sugestao }
    for ($n = 2; $n -lt 100; $n++) {
        $tentativa = "$Sugestao-$n"
        if (-not (Test-Path $tentativa)) { return $tentativa }
    }
    return "$Sugestao-$(Get-Date -Format 'HHmmss')"
}
