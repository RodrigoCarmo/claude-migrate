# claude-migrate

Scripts locais que copiam seu ambiente do Claude Code de uma máquina para outra:
configuração, hooks, skills, plugins, memórias e histórico de conversas. No destino,
verificam o que consegue rodar.

Windows, PowerShell 5.1. Requer `node` no PATH.

**Para migrar, siga o [GUIA.md](GUIA.md).** Este arquivo descreve o que o projeto faz.

---

## As peças

| Script | Onde roda | O que faz |
| --- | --- | --- |
| `exportar.ps1` | origem | coleta o ambiente num pacote, com inventário e manifesto |
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

## O que entra no pacote

| Item | Quando |
| --- | --- |
| `settings.json`, `settings.local.json`, `CLAUDE.md`, `mcp.json`, `keybindings.json` | sempre |
| `hooks/`, `skills/`, `commands/`, `agents/` | sempre |
| `plugins/` e marketplaces | sempre |
| `projects/*/memory/` | sempre |
| `settings.local.json` de cada repositório | sempre |
| `mcpServers` e configuração por projeto | sempre |
| transcrições, `history.jsonl`, `file-history/` | `-IncluirHistorico` |
| credenciais de sessão | `-IncluirSegredos` |

Ficam de fora: cache, telemetria, sessões por processo, identificadores de máquina,
a instalação do CLI e da extensão de editor, e integrações ligadas à conta.

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
- O import em modo de aplicação e a restauração a partir dos backups não foram exercitados
  em teste automatizado. Rode `-Simular` antes.
- Dependências internas dos scripts (bibliotecas, arquivos de configuração que eles leiam)
  não são verificadas.
