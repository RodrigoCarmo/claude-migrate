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
    # /XJF deixa symlink de arquivo de fora. O Claude Code aponta debug\latest para o log
    # da sessao, e o log e apagado antes do link: robocopy segue o symlink, nao acha o
    # alvo e devolve 9. Isso abortava o import inteiro por causa de um log volatil, com o
    # backup ja completo. Junction de diretorio continua sendo seguida (sem /XJD): quem
    # move plugins para outro disco quer os bytes dentro do backup.
    # robocopy usa 0-7 para sucesso e 8+ para erro real
    $null = Invoke-Externo -Programa 'robocopy' -Mensagem $Mensagem -ExitAceitavel 7 `
        -Argumentos @($De, $Para, '/E', '/XJF', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
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
Devolve o caminho pedido, ou o primeiro sufixado que ainda esteja livre.

Dois imports no mesmo segundo nao acontecem na pratica, mas colidir aqui
significaria despejar dois ambientes dentro da mesma pasta de backup.
#>
function Get-CaminhoLivre {
    param([Parameter(Mandatory)][string]$Caminho)

    if (-not (Test-Path $Caminho)) { return $Caminho }
    $tentativa = 2
    while (Test-Path "$Caminho-$tentativa") { $tentativa++ }
    return "$Caminho-$tentativa"
}

# ---------------------------------------------------------------------------
# Estado da migracao
#
# Trilha do que foi feito, nao substituto dos parametros: extrair.ps1 e
# importar.ps1 continuam exigindo os caminhos explicitamente. O estado serve
# para o verificador dizer de qual pacote o ambiente veio, e para registrar
# onde ficaram os backups de um import.
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

<#
Acrescenta um evento ao historico do estado, preservando os anteriores.

O estado tambem guarda as chaves do ultimo import, que o verificar.ps1 le. O
historico existe porque essas chaves sao sobrescritas a cada import: sem ele, o
caminho do backup de dois imports atras nao esta em lugar nenhum, alem do
carimbo no nome da pasta.
#>
function Add-HistoricoMigracao {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Evento)

    $historico = @()
    $atual = Get-EstadoMigracao
    if ($atual -and $atual.historico) { $historico = @($atual.historico) }

    return (Set-EstadoMigracao @{ historico = @($historico) + @([pscustomobject]$Evento) })
}

<#
Os backups de .claude que existem neste perfil, do mais recente para o mais
antigo, anotados com o que o historico souber sobre a origem de cada um.

Le o disco, e nao apenas o estado: um backup continua valido mesmo que o
.claude-migrate.json tenha sido apagado, e o inverso nao e verdade.
#>
function Get-BackupsDisponiveis {
    $historico = @()
    $estado = Get-EstadoMigracao
    if ($estado -and $estado.historico) { $historico = @($estado.historico) }

    # o .claude.bkp sem carimbo vem de uma versao anterior deste projeto, quando
    # havia um backup so: ainda e um ponto de retorno legitimo
    $pastas = @(Get-ChildItem $env:USERPROFILE -Filter '.claude.bkp*' -Directory -Force -ErrorAction SilentlyContinue)

    $lista = foreach ($pasta in $pastas) {
        # '.claude.bkp.20260825-143000' -> '.20260825-143000', e o .json de par
        # carrega o mesmo sufixo. '' no caso do backup sem carimbo.
        $sufixo = $pasta.Name.Substring('.claude.bkp'.Length)
        $json = Join-Path $env:USERPROFILE ".claude.json.bkp$sufixo"

        $evento = @($historico | Where-Object { $_.backupClaude -eq $pasta.FullName })[-1]
        $origem = 'sem registro no historico'
        if ($evento) {
            $origem = switch ($evento.acao) {
                'import'      { "antes do import de $(Split-Path $evento.pacote -Leaf)" }
                'restauracao' { "antes de restaurar $(Split-Path $evento.de -Leaf)" }
                default       { $evento.acao }
            }
        }

        [pscustomobject]@{
            Caminho = $pasta.FullName
            Nome    = $pasta.Name
            Quando  = $pasta.CreationTime
            Json    = $(if (Test-Path $json) { $json } else { $null })
            Origem  = $origem
        }
    }

    return @($lista | Sort-Object Quando -Descending)
}
