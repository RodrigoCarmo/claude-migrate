# claude-migrate

Scripts locais que copiam seu ambiente do Claude Code de uma máquina para outra:
configuração, hooks, skills, plugins, memórias e histórico de conversas. No destino,
verificam o que consegue rodar.

Windows, PowerShell 5.1. Requer `node` e `tar` no PATH — o `node` vem com o Claude Code
instalado via npm, e o `tar` acompanha o Windows desde a versão 1803. O export para se o
`tar` não estiver disponível: `Compress-Archive` não serve como substituto, porque
descarta arquivos e pastas ocultas e os `.git` dos marketplaces de plugin se perdem.

**Para migrar, siga o [GUIA.md](GUIA.md).** Este arquivo descreve o que o projeto faz.

---

## As peças

| Script | Onde roda | O que faz |
| --- | --- | --- |
| `exportar.ps1` | origem | coleta o ambiente num único `.tgz`, com inventário e manifesto |
| `extrair.ps1` | destino | abre o pacote e confere a integridade |
| `importar.ps1` | destino | faz backup, aplica, mescla e remapeia caminhos |
| `verificar.ps1` | destino | relata o que consegue rodar nesta máquina |

`lib/` contém os helpers em Node: inventário, histórico, leitura de configuração,
`settings.local.json` de projeto e o analisador do verificador.

O pacote gerado traz dois arquivos de apoio, além do ambiente em si:

- **`MANIFESTO.md`** — a ficha da máquina de origem: versões instaladas, pacotes npm globais
  e extensões de editor. É a lista de conferência do que instalar no destino, e o import a
  usa para detectar mudança de nome de usuário.
- **`INVENTARIO.txt`** — o tamanho de cada arquivo e uma assinatura da lista. O import
  confere antes de escrever e recusa pacote incompleto.

---

## Estado da migração

`extrair.ps1` e `importar.ps1` registram o que fizeram em `~\.claude-migrate.json`:
a pasta do pacote, o `.tgz` de origem, as datas e onde ficaram os backups.

Não substitui os parâmetros, que continuam obrigatórios e explícitos. Serve de trilha:
é dali que o verificador diz de qual pacote o ambiente veio, e é onde estão os caminhos
para desfazer um import.

---

## O que entra no pacote

| Item | Quando |
| --- | --- |
| `settings.json`, `settings.local.json`, `CLAUDE.md`, `mcp.json`, `keybindings.json` | sempre |
| `hooks/`, `skills/`, `commands/`, `agents/` | sempre |
| `plugins/` e marketplaces | sempre |
| `projects/*/memory/` | sempre |
| `settings.local.json` de cada repositório | sempre |
| `mcpServers` e configuração por projeto | sempre |
| transcrições, `history.jsonl`, `file-history/` | sempre, salvo `-SemHistorico` |
| credenciais de sessão | `-IncluirSegredos` |

Ficam de fora: cache, telemetria, sessões por processo, identificadores de máquina,
a instalação do CLI e da extensão de editor, e integrações ligadas à conta.

---

## Como o import resolve conflitos

O import não é um merge geral: são três regras diferentes, dependendo do arquivo. Medido
com dois perfis onde a mesma sessão existia em estados diferentes:

| Situação | O que acontece |
| --- | --- |
| arquivo existe no pacote e no destino | o do pacote **substitui** o local, inteiro |
| arquivo existe só no destino | **sobrevive** (o `robocopy` é `/E`, não `/MIR`) |
| `~\.claude.json` | **merge** chave a chave; em MCP de nome repetido, o local vence |

Duas consequências que valem saber antes de rodar:

- **Não há merge de conversa.** Um `.jsonl` com 5 mensagens no destino, contra 3 no
  pacote, termina com 3. As duas últimas ficam apenas no backup.
- **O pacote sobrescreve mesmo sendo mais antigo.** O `robocopy` é chamado sem `/XO`,
  então a idade do arquivo não entra na decisão. Importar no próprio PC que exportou
  funciona, e o efeito é reverter a máquina para o momento do export.

O backup (`~\.claude.bkp`) é criado **apenas na primeira vez**, de propósito, para não
destruir o registro do ambiente original. O efeito colateral é que, a partir do segundo
import, o trabalho intermediário não está nem no ambiente vivo nem no backup.

---

## Histórico de conversas

O Claude Code guarda as sessões numa pasta derivada do **caminho do projeto**, e lista as
sessões da pasta em que foi aberto.

Duas consequências:

- se o repositório ficar em outro caminho na máquina nova, as conversas ficam invisíveis
  até serem remapeadas. O import renomeia a pasta e reescreve o caminho gravado nas
  transcrições.
- abrir o Claude Code fora da pasta do repositório mostra uma lista vazia.

---

## Segurança

O pacote contém as credenciais dos servidores MCP e o conteúdo das conversas de quem
exportou.

Cada pessoa gera o seu. Ele não se compartilha e não serve para montar um ambiente padrão
de time. Apague depois de importar.

---

## O verificador

Responde se cada item do ambiente consegue rodar na máquina nova, em dois níveis:

**Garantido** — servidores MCP com comando no PATH, hooks com script e interpretador
disponíveis, caminhos que não ficaram presos ao perfil de origem, plugins com caminho
válido, diretórios adicionais que existem e regras de permissão de arquivo (`Read`, `Edit`,
`Write`, `Glob`, `Grep`) apontando para caminhos reais.

**Sinalizado** — ferramentas conhecidas invocadas por skills, commands e scripts de hook.
É pista, não veredito: reconhece por lista, então uma ferramenta incomum passa despercebida.

Não testa a lógica de nenhum hook e não executa nada de terceiros. O relatório termina
listando os hooks capazes de bloquear ações, que só o dono do ambiente pode validar.

---

## Limites

- Windows apenas. macOS e Linux não foram testados.
- O ciclo export → extrair → importar foi exercitado de ponta a ponta contra um perfil
  isolado, mas a **restauração a partir dos backups** nunca foi. Rode `-Simular` antes.
- Dependências internas dos scripts (bibliotecas, arquivos de configuração que eles leiam)
  não são verificadas.
- O arquivo de estado fica em `~\.claude-migrate.json` depois da migração; hoje nenhum
  script o remove.
- Os helpers fazem `JSON.parse` sem remover BOM. O Claude Code não grava `.claude.json`
  com BOM, mas um editor que salve assim faz o export falhar. O `lib/inventario.js` já
  trata; `exportar.ps1` e `importar.ps1` não.
- Não foi verificado se o `sessions-index.json`, copiado por cima, pode esconder do
  `/resume` uma sessão que existe apenas no destino.
