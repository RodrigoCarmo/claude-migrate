# Guia de migração

Windows, PowerShell 5.1. Precisa de `node` e `tar` no PATH: o `node` vem com o Claude Code
instalado via npm, e o `tar` acompanha o Windows desde a versão 1803.

## Origem

### 1. Feche o Claude Code

Todas as janelas, incluindo as do editor.

### 2. Exporte

```powershell
.\exportar.ps1 -Destino "$env:USERPROFILE\claude-backup.tgz"
```

`-Destino` é o arquivo que você quer ter no fim. Sem a extensão `.tgz`, ela é
acrescentada. O resultado é **um arquivo**: a pasta usada para montar o pacote fica ao
lado enquanto o export roda e é removida ao terminar.

| Switch | Efeito |
| --- | --- |
| `-SemHistorico` | deixa as conversas de fora |
| `-IncluirSegredos` | inclui token OAuth e credenciais (transporte criptografado) |

### 3. Transfira

Disco, pendrive ou canal interno. É um arquivo só, e não precisa de tratamento: não
reempacote nem renomeie a extensão.

Se passar por FTP ou ferramenta similar, use modo binário.

### 4. Limpe a origem

Apague o `.tgz` depois que o import do outro lado funcionar. Ele contém as credenciais
dos seus MCP e o conteúdo das suas conversas.

---

## Destino

### 5. Prepare a máquina

```powershell
npm i -g @anthropic-ai/claude-code
```

Clone seus repositórios, de preferência nos mesmos caminhos da origem. O `MANIFESTO.md`
dentro do pacote lista as versões e pacotes globais da máquina antiga.

### 6. Extraia

```powershell
.\extrair.ps1 -Arquivo "$env:USERPROFILE\Downloads\claude-backup.tgz" -Destino "D:\claude-restore"
```

Você escolhe o destino, e pode ser outro disco. Antes de extrair ele confere se o
arquivo chegou inteiro, se não é um placeholder do OneDrive e se o `tar` consegue abrir.
Depois tira a marca de origem dos scripts, que de outro modo faria seus hooks falharem
em silêncio.

Se a pasta de destino já tiver conteúdo, ele para e explica. Extrair por cima falharia
no meio, porque os `.pack` dos plugins são read-only. Para apagar e extrair do zero,
acrescente `-Limpar`.

### 7. Simule

```powershell
.\importar.ps1 -Pacote "D:\claude-restore" -Simular
```

Mostra o que faria, sem escrever nada. Confira duas linhas:

- `integridade do pacote — N arquivos conferem`
- `total que o /resume vai listar — N sessoes`

Se aparecerem sessões órfãs, o repositório está em outro caminho aqui:

```powershell
.\importar.ps1 -Pacote "D:\claude-restore" -Simular -RemapearPaths @{ 'C:\antigo' = 'D:\novo' }
```

### 8. Aplique

```powershell
.\importar.ps1 -Pacote "D:\claude-restore"
```

Faz backup de `~\.claude` e `~\.claude.json` antes de mexer, aplica e chama o verificador.
Os caminhos dos backups ficam registrados em `~\.claude-migrate.json`.

### 9. Leia o verificador

Ele roda sozinho ao fim do import, ou à parte com `.\verificar.ps1`.

| Bloco | O que fazer |
| --- | --- |
| Inventário | quanto de cada categoria está pronto |
| **CORRIJA** | resolva antes de usar: o item não funciona |
| **CONFIRME** | sinalizado pelo texto, pode ser falso positivo |
| **VALIDE A MAO** | hooks que bloqueiam ações: só você sabe se ainda decidem certo |

### 10. Suba o Claude Code

```powershell
claude
```

Dentro dele: `/login`, `/mcp`, `/doctor` e `/resume`. Abra sempre na pasta do repositório
para ver as conversas daquele projeto.

Faltam ainda a extensão do editor, o acesso de rede aos hosts dos seus MCP e as
ferramentas de linha de comando que suas skills usem.

### 11. Limpe o destino

Com tudo funcionando, apague o `.tgz` e a pasta extraída.

---

## Parâmetros

| Script | Obrigatórios | Opcionais |
| --- | --- | --- |
| `exportar.ps1` | `-Destino` (o arquivo `.tgz`) | `-SemHistorico`, `-IncluirSegredos` |
| `extrair.ps1` | `-Arquivo`, `-Destino` | `-Limpar` |
| `importar.ps1` | `-Pacote` | `-Simular`, `-RemapearPaths` |
| `verificar.ps1` | | `-SemCor` |

---

## Problemas comuns

| Sintoma | Solução |
| --- | --- |
| `tar nao encontrado no PATH` | Windows anterior a 1803; instale o Git for Windows, que traz `tar` |
| `node nao encontrado no PATH` | instale o Claude Code via npm, ou o Node por fora |
| `o destino e uma pasta existente` | `-Destino` deve ser o arquivo `.tgz`, não uma pasta |
| `caminho de destino invalido` | há caractere que o Windows não aceita em nome de arquivo |
| `falha ao compactar o pacote` | destino sem espaço, inacessível, ou o `.tgz` travado por outro processo |
| `o pacote gerado nao pode ser lido de volta` | o `.tgz` saiu corrompido; rode o export de novo |
| `o destino e a pasta deste projeto` | extrair ali sobrescreveria os scripts em uso; escolha outro lugar |
| `o tar nao conseguiu abrir o arquivo` | o `.tgz` corrompeu na transferência, ou foi enviado em modo texto |
| `a pasta de destino nao esta vazia` | use `-Limpar`, ou aponte `-Destino` para pasta nova |
| `o arquivo informado nao existe` | confira o caminho passado em `-Arquivo` |
| `nao parece um pacote de migracao` | a pasta em `-Pacote` não tem `.claude\` dentro |
| `arquivo pequeno demais` | a transferência não terminou, copie de novo |
| `placeholder do OneDrive` | botão direito no `.tgz` > "Sempre manter neste dispositivo" |
| `pacote incompleto` | o `.tgz` chegou truncado, ou editaram arquivos do pacote |
| `não está assinado digitalmente` | `Get-ChildItem <pasta> -Recurse -File -Include *.ps1,*.js \| Unblock-File` |
| script não executa | `powershell -ExecutionPolicy Bypass -File .\verificar.ps1` |
| conversas não aparecem | abra o Claude na pasta do repositório; se faltarem, veja o passo 7 |
| glifos saem como `+` e `-` | o console não está em UTF-8; a saída continua correta, só em ASCII |
| quer voltar atrás | apague o que veio e renomeie `~\.claude.bkp` e `~\.claude.json.bkp` |
