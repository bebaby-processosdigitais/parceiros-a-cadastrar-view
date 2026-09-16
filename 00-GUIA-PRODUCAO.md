# Guia de implantação em produção

Cadastro de parceiros a partir do XML importado, operado por uma tela sobre view.

**Escopo deste guia:** montar a view `AD_VWPARCXML` e colocar o botão "Cadastrar
Parceiros" funcionando nela. Nada além disso.

**Estado:** validado em homologação em 11/09/2026 — 13 parceiros criados, e duas notas
processaram com o parceiro criado pelo robô (NUNOTA 193189 e 193190).

---

## O que este conjunto resolve

As notas do Full que sobem pelo Portal de Importação de XML **não cadastram o parceiro**.
O motor de importação exige "parceiro cliente ativo" e recusa a nota se não achar — a
divergência aparece no Portal como:

> Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF 03846853747.

Hoje alguém cadastra à mão, copiando do XML. A view mostra quem falta, e o botão cadastra.

**Confirmado:** o motor **não** cria o parceiro. Ele localiza e falha. O cadastro é
pré-requisito para a nota processar.

---

## Arquivos

| # | Arquivo | O que é |
|---|---|---|
| 1 | `01-view-parceiros-xml.sql` | A view. Roda no banco |
| 2 | `02-cadastrar-parceiros-view.js` | O botão. Cola numa ação de tela |
| 3 | `03-verificacao.sql` | Queries de conferência |
| 4 | `04-funcao-limpa-divergencia.sql` | Função que apaga a mensagem antiga. Roda no banco |

---

## Pré-requisitos

- Acesso direto ao banco para `CREATE VIEW` (o DBExplorer do Sankhya é **somente
  leitura** — use SQL Developer ou equivalente)
- Acesso ao Construtor de Telas
- Saída de rede da aplicação para `https://viacep.com.br` — o Sankhya já usa esse
  serviço, então costuma estar liberada

---

## PARTE 1 — A view

### 1.1 Testar antes de criar

Abra `01-view-parceiros-xml.sql`, **apague a primeira linha**
(`CREATE OR REPLACE VIEW AD_VWPARCXML AS`) e rode o resto.

Confira:

- Retorna linhas, e nenhum `NUARQUIVO` repetido
- `ORIGEM` mostra ML FULL e AMAZON FULL
- Tempo aceitável

⚠️ **Se demorar**, é volume: a janela de dias é o que controla. Medições em produção com
1.386 notas em 90 dias deram 63s; a versão entregue usa 2 dias.

⚠️ **Se demorar mais de 30 segundos**, confirme que os hints `/*+ MATERIALIZE */`
estão presentes nas três CTEs. Sem eles a consulta leva 30s em vez de 1,5s — o Oracle
reavalia a extração do XML uma vez por coluna agregada.

### 1.2 Criar a view — a ordem importa

⚠️ **O Sankhya não registra view que já existe.** Tentar cadastrar a tela apontando para
uma view existente dá `CORE_E03093: Já existe uma tabela com o nome AD_VWPARCXML`.

O caminho é inverso: cria a tabela pelo assistente, converte em view, e só então
substitui a definição.

**a)** Construtor de Telas → **+** → "Cadastrar Tela Adicional" → **Tela Mestre**

| Campo | Valor |
|---|---|
| Descrição da Tela | `Parceiros a Cadastrar (XML)` |
| Nome da tabela no banco de dados | `VWPARCXML` |

⚠️ Digite só `VWPARCXML` — o sistema prefixa com `AD_`.
⚠️ O Construtor **não aceita underline** em nome de tabela nem de campo. Por isso as
colunas da view são `NOMEXML`, `QTDNOTAS`, `ENDERECOOK` e não `NOME_XML` etc.

**b)** Chave primária: `NUARQUIVO`, **Número Inteiro**, Padrão.
⚠️ Na tela seguinte, **NÃO marque auto-numeração** — view não gera código.

**c)** Aba **Campos**, criar os demais. Ligue **"Permite pesquisa?"** e
**"Visível no grid de pesquisa?"** em todos — sem isso o campo não aparece na grade.

| Campo | Descrição | Tipo | Apresentação |
|---|---|---|---|
| `ORIGEM` | Origem | Texto | Padrão |
| `DHIMPORT` | Importado em | Data e Hora | Padrão |
| `DOCUMENTO` | CNPJ/CPF | Texto | Caixa de Texto |
| `TIPPESSOA` | Tipo | Texto | Padrão |
| `NOMEXML` | Nome no XML | Texto | Caixa de Texto |
| `QTDNOTAS` | Notas pendentes | Número Inteiro | Padrão |
| `CADASTRADO` | Cadastrado? (filtro) | Texto | Padrão |
| `CADASTRADOCOR` | Situação | Texto | **Formatação HTML** |
| `CODPARC` | Cód. Parceiro | Número Inteiro | Padrão |
| `NOMEPARC` | Nome no cadastro | Texto | Padrão |
| `CLIENTE` | Cliente? | Texto | Padrão |
| `ATIVO` | Ativo? | Texto | Padrão |
| `ENDERECOOK` | Endereço? (filtro) | Texto | Padrão |
| `ENDERECOCOR` | Endereço | Texto | **Formatação HTML** |
| `CEP` | CEP | Texto | Caixa de Texto |
| `LOGRADOURO` | Logradouro | Texto | Caixa de Texto |
| `NUMERO` | Número | Texto | Caixa de Texto |
| `BAIRRO` | Bairro | Texto | Caixa de Texto |
| `MUNICIPIO` | Município | Texto | Caixa de Texto |
| `UF` | UF | Texto | Caixa de Texto |
| `CODCID` | Cód. Cidade | Número Inteiro | Padrão |
| `CIDADEOK` | Cidade OK? | Texto | Padrão |

⚠️ **Caixa de Texto** nos campos que a view devolve como `VARCHAR2(4000)` — resultado de
`TO_CHAR` sobre CLOB. Com "Padrão" (`VARCHAR(100)`) o tipo é incompatível.

⚠️ Se o toggle "Permite pesquisa?" der `CORE_E01922`, **não é regra do produto** — é
sessão ou cache. Saia e entre no sistema e tente de novo.

**d)** Com a instância selecionada → **"Outras Opções" → "Transformar Tabela em View"**.

A tabela está vazia, então confirme. O Sankhya apaga a tabela e cria uma view-esqueleto.
Conferir:

```sql
SELECT OBJECT_NAME, OBJECT_TYPE FROM USER_OBJECTS
WHERE OBJECT_NAME = 'AD_VWPARCXML'
```

Tem que vir `VIEW`. **A tabela deixa de existir** — nada fica armazenado.

**e)** No banco, rode `01-view-parceiros-xml.sql` **inteiro**, com o
`CREATE OR REPLACE VIEW`. Isso troca o esqueleto pela consulta real.

⚠️ **Use F5 (Run Script), não Ctrl+Enter.** Comando longo de várias linhas pode executar
parcial no SQL Developer, e o `CREATE OR REPLACE` não avisa que ficou pela metade.

⚠️ **Confira depois de recriar.** Em 16/09/2026 a view em produção estava com uma versão
antiga do filtro de CNPJ (quatro underscores em vez de seis) e ninguém notou: ela não dava
erro, só deixava de mostrar as notas cujo `NOMEARQUIVO` não contém o CNPJ — justamente as
de upload manual, que são o caso de uso da tela. Eram 182 notas elegíveis e 43 na tela.

```sql
SELECT COUNT(*) FROM AD_VWPARCXML;

-- compare com o que deveria entrar
SELECT COUNT(*) FROM TGFIXN
WHERE STATUS = 0 AND DHIMPORT >= SYSDATE - 30
  AND (NOMEARQUIVO LIKE '%2841455800%' OR CHAVEACESSO LIKE '______2841455800%')
  AND INSTR(XML, '</dest>') > INSTR(XML, '<dest>');
```

O segundo é maior que o primeiro (a view agrupa por documento), mas uma diferença grande
demais é sinal de versão errada no banco.

Confirme que as colunas batem com os campos criados:

```sql
SELECT COLUMN_ID, COLUMN_NAME, DATA_TYPE, DATA_LENGTH
FROM USER_TAB_COLUMNS WHERE TABLE_NAME = 'AD_VWPARCXML' ORDER BY COLUMN_ID
```

Toda divergência de nome dá erro ao abrir a tela.

**f)** **"Outras Opções" → "Definir chave primária para a unidade de dados"** →
`NUARQUIVO`.

⚠️ Obrigatório. View não tem constraint, então é aqui que o Sankhya aprende a PK.

**g)** **"Outras Opções" → "Reiniciar esta unidade de dados"**.

### 1.3 Publicar e configurar a grade

**"Outras Opções" → "Adicionar lançador"**, informando a descrição e a pasta de destino.

**"Outras Opções" → "Definir ordem dos campos"**, na ordem de leitura:

```
NUARQUIVO · CADASTRADOCOR · ENDERECOCOR · ORIGEM · DHIMPORT ·
NOMEXML · DOCUMENTO · TIPPESSOA · QTDNOTAS ·
CODPARC · NOMEPARC · CEP · LOGRADOURO · NUMERO · BAIRRO ·
MUNICIPIO · UF · CODCID · CIDADEOK · CADASTRADO · ENDERECOOK · CLIENTE · ATIVO
```

As colunas de texto puro (`CADASTRADO`, `ENDERECOOK`) ficam no fim — servem para filtro,
não para leitura.

**"Outras Opções" → "Avançado" → Campo para apresentação** = `NOMEXML`.

### 1.4 Painel de filtros

**"Outras Opções" → "Painel de Filtros"** → "Adicionar filtro":

| Campo | Tipo | Para quê |
|---|---|---|
| `DHIMPORT` | Período | recorte por data |
| `CADASTRADO` | Multi-seleção | ver só os `NAO` |
| `ORIGEM` | Multi-seleção | separar ML de Amazon |

Filtro de Período **não precisa de expressão SQL** — o Sankhya monta sozinho.

---

## PARTE 1.5 — A função de limpeza (OPCIONAL, vem desligada)

⚠️ **Você provavelmente não precisa desta parte.** Confirmado em 12/09/2026: quando a nota
processa, o motor reescreve o `CONFIG` e o aviso some sozinho. Por isso o script vem com
`LIMPAR_DIVERG = false`.

A função continua aqui porque é útil em dois casos: limpar ruído acumulado de notas antigas
que nunca vão processar, e diagnosticar. Se for esse o seu caso, siga adiante; senão, pule
para a Parte 2.

A mensagem de divergência fica gravada na coluna `CONFIG` da `TGFIXN` desde o upload, e não
é reavaliada enquanto a nota não processa. A função `STP_LIMPA_DIVERG_PARC` remove a frase
do parceiro. O botão a chama depois de cadastrar, **se o interruptor estiver ligado**.

### Criar

No banco, rode `04-funcao-limpa-divergencia.sql`.

```sql
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS
WHERE OBJECT_NAME = 'STP_LIMPA_DIVERG_PARC'
```

Tem que vir `FUNCTION` e `VALID`. Se vier `INVALID`:

```sql
SELECT LINE, POSITION, TEXT FROM USER_ERRORS
WHERE NAME = 'STP_LIMPA_DIVERG_PARC' ORDER BY SEQUENCE
```

### Testar isolada, antes de ligar no botão

```sql
-- antes
SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 600)) AS CONFIG_TXT
FROM TGFIXN WHERE STATUS = 0 AND INSTR(CONFIG, '03846853747') > 0;

-- limpa
SELECT STP_LIMPA_DIVERG_PARC('03846853747') AS NOTAS_LIMPAS FROM DUAL;

-- depois
SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 600)) AS CONFIG_TXT
FROM TGFIXN WHERE NUARQUIVO IN (/* os da primeira consulta */);
```

Trocando o CPF por um que tenha divergência na sua base.

### Por que é função, e não UPDATE no script

Não existe `UPDATE` via script de ação nesta instalação. Função pode ser chamada de dentro
de um `SELECT` — e `SELECT` o script faz. O `PRAGMA AUTONOMOUS_TRANSACTION` permite o
`COMMIT` sem interferir na transação do script.

### O que ela remove

**Apenas a frase** "Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF X".

Isso importa porque o mesmo bloco `<divDevolucao>` pode conter **outras validações**. Caso
real da nota 109154:

```
Tipo de Operação não informado em Outras Opções > Preferências...
Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF X.
```

Apagar o bloco inteiro levaria junto o aviso de Tipo de Operação, que é outro problema e
continua sem solução.

Quando a frase do parceiro é a **única** validação, a coluna fica completamente vazia. O
cabeçalho `XML: nome-do-arquivo.xml` não conta como conteúdo — sem a frase ele fica órfão
e não diz nada.

Validado contra os quatro formatos que existem na base:

| Situação | Resultado |
|---|---|
| Só a frase do parceiro | `CONFIG` vira `NULL` |
| Idem, com chave em vez de `.xml` no cabeçalho | `CONFIG` vira `NULL` |
| Duas validações, multilinha | mantém a outra |
| Duas validações em linha única (formato de 2023) | mantém a outra |

A limpeza é **por documento**, não por nota: a view agrupa, e um cliente pode ter várias
notas pendentes com a mesma mensagem.

### Quando o botão chama

Só depois de **confirmar no banco** que o parceiro foi criado e satisfaz o que o motor
exige (`CLIENTE = 'S'` e `ATIVO = 'S'`). O `save()` ter passado não basta: apagar a
divergência de um parceiro inexistente esconderia um problema real.

Não limpa quando o parceiro **já existia** — nesse caso o botão não fez nada, e a
mensagem não é dele para apagar.

⚠️ `CONFIG` é coluna do motor de importação. Se não quiser mexer nela, deixe
`LIMPAR_DIVERG = false` no script — o cadastro funciona igual, só a mensagem antiga
permanece.

⚠️ Se a função não existir no banco, a chamada falha **em silêncio** e o cadastro segue
normalmente. Foi o comportamento observado antes de criá-la: o parceiro nascia certo, mas
a linha "DIVERGENCIAS LIMPAS" não aparecia no resumo.

⚠️ **Antes de usar em produção**, vale confirmar se o problema existe lá:

```sql
SELECT COUNT(*) AS PROCESSADAS_COM_DIVERGENCIA
FROM TGFIXN
WHERE STATUS = 5
  AND UPPER(TO_CHAR(SUBSTR(CONFIG, 1, 4000))) LIKE '%NAO FOI ENCONTRADO%'
```

Se der **zero**, o motor reescreve o `CONFIG` ao processar com sucesso — e a função é
desnecessária.

---

## PARTE 2 — O botão

### 2.1 Criar a ação

Aba **Ações** da instância `AD_VWPARCXML` → incluir:

| Campo | Valor |
|---|---|
| Descrição | `Cadastrar Parceiros` |
| Tipo | **Script (JavaScript)** |
| Controla Acesso | **marcado** |
| Depois de executar, recarregar | **Toda a grade** |

Cole `02-cadastrar-parceiros-view.js`.

O "Toda a grade" faz a linha mudar de `NAO` para `CADASTRADO` sozinha — as colunas são
calculadas na consulta, não gravadas.

### 2.2 Configuração do script

No topo do arquivo:

| Variável | Produção | O que faz |
|---|---|---|
| `MODO_SIMULACAO` | **`true` no começo** | só relata, não grava |
| `USAR_TSICEP` | `true` | busca endereço no cache local |
| `USAR_VIACEP` | `true` | consulta o ViaCEP quando o cache não tem |
| `MAX_LINHAS` | `10` | teto por clique |
| `CODBAI_CENTRO` | `866` | CODBAI genérico para "CENTRO" |
| `NAO_CADASTRAR` | 3 raízes | BeBaby, Amazon, EBAZAR |
| `LIMPAR_DIVERG` | **`false`** | apaga a mensagem antiga. Desligado — ver Parte 1.5 |

⚠️ **Confirme o `CODBAI_CENTRO` em produção.** O 866 foi definido em homologação:

```sql
SELECT B.CODBAI, B.NOMEBAI,
       (SELECT COUNT(DISTINCT C.CODCID) FROM TSICEP C WHERE C.CODBAI = B.CODBAI) AS CIDADES
FROM TSIBAI B WHERE B.CODBAI = 866
```

Se `NOMEBAI` não for "CENTRO", ajuste a constante.

### 2.3 Sequência de testes

**a)** `MODO_SIMULACAO = true`, selecione 2 ou 3 linhas com `CADASTRADO = NAO`.

O relatório mostra por linha o que seria criado e a origem do endereço
(`TSICEP` ou `VIACEP (criaria: ...)`).

**b)** ⚠️ **Confira a contraparte antes de gravar.** Se o script escolher o lado errado,
cadastraria a própria empresa como parceiro — e não há `DELETE` disponível para desfazer.

O `NOMEXML` **não pode** ser "BEBABY GROUP IMPORTACAO LTDA".

**c)** `MODO_SIMULACAO = false` com **uma linha só**.

**d)** Conferir — ver `03-verificacao.sql`.

**e)** Rodar de novo na mesma linha. Deve dar `JA EXISTIAM: 1` e não duplicar.

**f)** Só então liberar o uso normal.

---

## O que o botão faz

```
Linhas SELECIONADAS na grade
        ↓
Para cada uma: lê o NUARQUIVO, busca o XML na TGFIXN
        ↓
Extrai o bloco <dest>. O parceiro é o lado que NÃO é a BeBaby
(o CNPJ dela sai das posições 7–20 da própria chave de acesso)
        ↓
Está na lista de exclusão? → ignora (BeBaby, Amazon, EBAZAR)
        ↓
Parceiro já existe? → registra e pula
        ↓
Cidade: TSICID.CODMUNFIS = <cMun> do XML. NUNCA cria cidade
        ↓
Endereço em três níveis:
   1. TSICEP        → CODCID + CODBAI + CODEND já vinculados
   2. ViaCEP        → cria logradouro e bairro, e alimenta a TSICEP
   3. só a cidade   → CODEND = 0, como a própria integração faz
        ↓
Cria em TGFPAR com CODPARC = MAX(CODPARC) + 1
```

### Decisões que valem saber antes de mexer

**`CLIENTE = 'S'` explícito.** É o único campo em que o default do dicionário do Sankhya
(`'N'`) vence o default do banco (`'S'`). Parceiro com `CLIENTE = 'N'` não satisfaz o
"cliente ativo" que o motor exige. Dos 67 campos `NOT NULL` da `TGFPAR`, 62 têm default
no banco e os defaults servem para consumidor final.

**Não cria cidade.** A base do Sankhya já vem com os municípios do IBGE. Se a cidade não
existir, a linha falha com mensagem clara em vez de criar um município inventado.

**Bairro e logradouro: busca antes de criar.** O Sankhya valida duplicata de bairro
(`CORE_E00959: Já existe um bairro cadastrado com o nome X`) — logo, é catálogo global
compartilhado entre cidades, por design.

**Normalização.** Nomes vão para o banco em CAIXA ALTA, sem acento e sem caractere
especial. As fontes divergem: o XML vem sem acento, o ViaCEP vem com, e o marketplace às
vezes manda entidade HTML (`Gon&ccedil;alves`). Sem normalizar, a `TSIBAI` acumularia
várias grafias do mesmo bairro.

**`CODPARC` = `MAX + 1`.** Não existe sequence. Há risco de colisão se alguém cadastrar
pela tela no mesmo instante — não corrompe nada, e o script tenta 3 vezes.

**Endereço vazio é comportamento correto**, não concessão: o parceiro 61662, criado pela
própria integração em produção, tem `CEP` preenchido e `CODEND = 0`.

---

## Limitações conhecidas

**A view mostra os últimos 2 dias, só `STATUS = 0`.** É a lista de trabalho do dia, com
cadastrados e não cadastrados. Ampliar a janela é uma linha no SQL — mas meça o tempo
depois, porque o custo cresce rápido.

**CEP geral de município não tem logradouro.** O ViaCEP devolve campos vazios (ex.:
`87430000`, Tapejara/PR). Não é falha do serviço — nem a tela do Sankhya resolve esses.
O parceiro nasce com a cidade certa e sem logradouro.

**A mensagem de divergência não se apaga sozinha.** Ela fica gravada na coluna `CONFIG`
da `TGFIXN`, dentro de `<validacoes><divDevolucao>`, desde o momento do upload. Cadastrar
o parceiro **não** limpa o texto — mas a nota passa a processar normalmente.

Vale confirmar em produção se um processamento completo reescreve o `CONFIG`:

```sql
SELECT COUNT(*) AS PROCESSADAS_COM_DIVERGENCIA
FROM TGFIXN
WHERE STATUS = 5
  AND UPPER(TO_CHAR(SUBSTR(CONFIG, 1, 4000))) LIKE '%NAO FOI ENCONTRADO%'
```

Se der zero, o motor limpa ao processar e não há nada a resolver.

**View é somente leitura.** O script não grava resultado na linha — o retorno vem pela
mensagem, e as colunas se atualizam ao recarregar a grade.

---

## Não validado

| Item | Situação |
|---|---|
| Contraparte **pessoa jurídica** (`TIPPESSOA = 'J'`) | Cadastrado 1 caso (Amazon), mas por engano — a lista de exclusão não estava ativa |
| Parceiro sendo o **emitente** | Em 98 documentos diagnosticados a BeBaby era sempre a emitente; esse ramo nunca executou |
| Nome/razão social acima de 80 caracteres | Não houve caso. O script trunca sem erro |

---

## Checklist

**View**
- [ ] SELECT testado, sem `NUARQUIVO` repetido, tempo aceitável
- [ ] Hints `/*+ MATERIALIZE */` presentes
- [ ] Tabela criada pelo assistente, PK `NUARQUIVO` sem auto-numeração
- [ ] 23 campos criados, com os dois toggles de pesquisa ligados
- [ ] "Transformar Tabela em View" executado, `OBJECT_TYPE = VIEW`
- [ ] `CREATE OR REPLACE VIEW` rodado, colunas conferidas
- [ ] "Definir chave primária para a unidade de dados"
- [ ] "Reiniciar esta unidade de dados"
- [ ] Lançador criado, ordem dos campos definida
- [ ] Painel de filtros configurado

**Função de limpeza — só se for usar (vem desligada)**
- [ ] `STP_LIMPA_DIVERG_PARC` criada e `VALID`
- [ ] Testada isolada, com um documento real
- [ ] `LIMPAR_DIVERG = true` no script

**Liberar para os usuários**
- [ ] Acesso à tela `AD_VWPARCXML` em Controle de Acesso > Acessos
- [ ] Acesso à ação "Cadastrar Parceiros" (foi criada com Controla Acesso ligado)
- [ ] **Acesso aos campos**, marcando PERMITIDO e REPASSAR
- [ ] Testado com o usuário final, não com o de administrador

**Botão**
- [ ] `CODBAI_CENTRO` confirmado em produção
- [ ] Ação criada com "Controla Acesso" e "Toda a grade"
- [ ] Simulação rodada, contraparte conferida
- [ ] Uma linha gravada e conferida campo a campo
- [ ] Repetição na mesma linha não duplicou
- [ ] Acesso liberado a quem vai operar
- [ ] Quem opera sabe o que o botão faz
