# Guia de migração

Scripts locais que copiam seu ambiente do Claude Code de uma máquina para outra:
configuração, hooks, skills, plugins, memórias e histórico de conversas.


## Pré-requisitos

Na máquina de destino, antes do passo 7:

- Node e Claude Code instalados
- os pacotes globais que seus servidores MCP usam
- seus repositórios clonados, de preferência nos mesmos caminhos da origem
- a pasta deste projeto, junto do `.tgz`

O pacote traz um `MANIFESTO.md` com as versões e os pacotes globais da máquina de origem.
Use como lista de conferência. O `verificar.ps1`, no passo 9, aponta o que ainda falta.

---

## Origem

### 1. Feche o Claude Code

Todas as janelas, incluindo as do editor.

### 2. Exporte

```powershell
.\exportar.ps1 -Destino "$env:USERPROFILE\claude-backup" -IncluirHistorico -Compactar
```

`-IncluirHistorico` leva as conversas. `-Compactar` gera o `.tgz`.

### 3. Transfira o `.tgz`

Disco, pendrive ou canal interno. Não reempacote com o zip do Windows.

O pacote contém as credenciais dos seus servidores MCP e o conteúdo das suas conversas.
Apague-o depois de importar.

---

## Destino

### 4. Instale o Claude Code

```powershell
npm i -g @anthropic-ai/claude-code
```

### 5. Clone seus repositórios

Nos mesmos caminhos da máquina de origem, sempre que possível.

### 6. Extraia o pacote

```powershell
.\extrair.ps1 -Arquivo 'D:\claude-backup.tgz'
```

Extrai em `%USERPROFILE%\claude-backup` e confere a integridade.

### 7. Simule o import

```powershell
cd "$env:USERPROFILE\claude-backup"
.\importar.ps1 -Pacote . -Simular
```

Mostra o que faria, sem escrever nada. Confira duas linhas:

- `pacote completo: N arquivos conferem`
- `total: N sessoes que o /resume vai listar`

Se aparecer `ORFA`, o repositório está em outro caminho aqui:

```powershell
.\importar.ps1 -Pacote . -Simular -RemapearPaths @{ 'C:\antigo\repo' = 'D:\novo\repo' }
```

### 8. Aplique

```powershell
.\importar.ps1 -Pacote .
```

Faz backup de `~/.claude` e `~/.claude.json`, aplica e chama o verificador.

### 9. Verifique

```powershell
.\verificar.ps1
```

| Bloco | O que fazer |
| --- | --- |
| resumo | quanto de cada categoria está pronto |
| **CORRIJA** | resolva antes de usar |
| **CONFIRME** | possível dependência, confirme se é real |
| **VALIDE A MAO** | hooks que bloqueiam ações: teste se ainda decidem certo |

### 10. Suba o Claude Code

```powershell
claude
```

Dentro dele: `/login`, `/mcp`, `/doctor` e `/resume`.

Abra sempre na pasta do repositório para ver as conversas daquele projeto.

### 11. Complete o ambiente

- extensão do editor, pelo marketplace do editor
- acesso de rede aos hosts dos seus servidores MCP
- ferramentas de linha de comando que suas skills usem

---

## Problemas comuns

| Sintoma | Solução |
| --- | --- |
| `tar: Error opening archive` | use caminho completo, ou o `extrair.ps1` |
| `Can't unlink already-existing object` | destino já tem conteúdo: `.\extrair.ps1 -Limpar` |
| `não está assinado digitalmente` | `Get-ChildItem <pasta> -Recurse -File -Include *.ps1,*.js \| Unblock-File` |
| script não executa | `powershell -ExecutionPolicy Bypass -File .\verificar.ps1` |
| conversas não aparecem | abra o Claude na pasta do repositório; se faltarem, veja `ORFA` no passo 7 |
| quer voltar atrás | apague o que veio e renomeie `~/.claude.bkp` e `~/.claude.json.bkp` |
