# Cadastro automático de parceiros a partir do XML — Sankhya

Tela sobre view que lista os parceiros faltantes das notas do Full, e um botão que os
cadastra na `TGFPAR` extraindo os dados do bloco `<dest>` do XML.

**Estado:** ciclo completo validado em homologação em 11/09/2026.

---

## Índice

- [O problema](#o-problema)
- [Visão geral](#visão-geral)
- [Arquivos](#arquivos)
- [`01` — A view](#01--a-view)
- [`02` — O botão](#02--o-botão)
- [`04` — A função de limpeza](#04--a-função-de-limpeza)
- [Decisões e o porquê](#decisões-e-o-porquê)
- [Limitações](#limitações)
- [Diagnóstico rápido](#diagnóstico-rápido)

---

## O problema

As notas do Full (Mercado Livre e Amazon) sobem pelo **Portal de Importação de XML**. O
motor de importação exige **parceiro cliente ativo** e recusa a nota se não encontrar:

> Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF 03846853747.

O motor **não** cria o parceiro — ele localiza e falha. Hoje alguém cadastra à mão,
copiando do XML. Foram ~90 cadastros manuais em 90 dias, em lotes (33 numa única tarde).

---

## Visão geral

```
XML sobe pelo Portal (grava na TGFIXN)
        ↓
view AD_VWPARCXML lista quem falta cadastrar
        ↓
operador seleciona as linhas e clica em "Cadastrar Parceiros"
        ↓
script lê o <dest> do XML, resolve o endereço e cria em TGFPAR
        ↓
função STP_LIMPA_DIVERG_PARC apaga a mensagem de divergência
        ↓
a nota processa
```

---

## Arquivos

| # | Arquivo | Onde roda |
|---|---|---|
| — | `CONTEXTO-PARA-NOVO-CHAT.md` | histórico completo e descobertas |
| 0 | `00-GUIA-PRODUCAO.md` | passo a passo de implantação |
| 1 | `01-view-parceiros-xml.sql` | **banco** (SQL Developer) |
| 2 | `02-cadastrar-parceiros-view.js` | **Sankhya** (ação Script) |
| 3 | `03-verificacao.sql` | banco |
| 4 | `04-funcao-limpa-divergencia.sql` | **banco** |

⚠️ Só o `02` vai no Sankhya. Os outros são SQL.
⚠️ O DBExplorer do Sankhya é **somente leitura** — `CREATE` precisa de acesso direto.

---

## `01` — A view

Uma linha **por documento**, não por nota. Se um cliente tem três notas pendentes, ele
aparece uma vez com `QTDNOTAS = 3`.

### Como ela monta os dados

Quatro etapas encadeadas (CTEs):

**`NOTAS`** — filtra as notas pendentes e recorta dois pedaços do XML: a chave de acesso e
o bloco `<dest>` inteiro.

```sql
WHERE X.STATUS = 0
  AND X.DHIMPORT >= SYSDATE - 2
  AND (X.NOMEARQUIVO LIKE '%2841455800%' OR X.CHAVEACESSO LIKE '______2841455800%')
```

**`EXTRAIDO`** — tira do bloco `<dest>` o nome, documento, CEP, IBGE, município, UF,
logradouro, número e bairro. E da chave, o CNPJ do emitente (posições 7–20).

A janela de **2 dias** é deliberada: a view é a lista de trabalho do dia, não um histórico.

**`DOFULL`** — mantém só os dois CNPJs da BeBaby e traduz o emitente em `ORIGEM`:

| CNPJ do emitente | Origem |
|---|---|
| `28414558000132` | ML FULL |
| `28414558000213` | AMAZON FULL |

**`AGRUPADO`** — agrupa por documento, pegando a primeira nota como referência.

Depois, três `LEFT JOIN`: `TGFPAR` (o parceiro existe?), `TSICEP` (o CEP resolve?) e
`TSICID` (a cidade existe?).

### Colunas que importam

| Coluna | O que diz |
|---|---|
| `CADASTRADO` | `SIM` / `NAO` / `NAO E CLIENTE` / `INATIVO` |
| `CADASTRADOCOR` | a mesma coisa, colorida (HTML) |
| `ENDERECOOK` | `SIM` / `FALTA ENDERECO` / `AUTOMATICO` / `DIGITAR CEP NA TELA` |
| `ENDERECOCOR` | a mesma coisa, colorida |
| `QTDNOTAS` | quantas notas dependem desse parceiro |
| `CIDADEOK` | se o código IBGE existe na `TSICID` |

**Por que duas colunas para a mesma informação:** filtro não funciona em coluna de HTML.
A de texto puro serve para filtrar, a colorida para ler. As de texto ficam no fim da grade.

O `CADASTRADO` tem quatro valores porque o motor exige "cliente **ativo**": parceiro que
existe mas está com `CLIENTE = 'N'` ou `ATIVO = 'N'` **não serve**, e um SIM/NÃO simples
esconderia isso.

A view traz **tudo** da janela — cadastrados e não cadastrados. Para ver só o que falta,
filtre por `CADASTRADO <> 'SIM'` no painel.

### Desempenho

Duas coisas sustentam o tempo da view, e as duas foram medidas.

**Os hints `/*+ MATERIALIZE */`** nas quatro CTEs. Sem eles o Oracle não guarda o resultado
intermediário: no `GROUP BY` com nove `MIN()`, ele reavalia toda a cadeia de extração do
XML **uma vez por coluna agregada** — nove releituras do CLOB por nota. Em homologação era
a diferença entre 30s e 1,5s.

**A janela de dias.** É o que controla o volume que chega à extração.

Medições em produção, com 1.386 notas em 90 dias:

| Versão | Tempo |
|---|---|
| 90 dias, sem filtro de pendentes | 63s |
| + `MATERIALIZE` no `AGRUPADO` | 53s |
| + janela de 30 dias | 44s |
| + descarta quem já tem parceiro | 19s |
| tudo junto, 30 dias | 12s |

**A versão entregue usa janela de 2 dias e traz tudo.** O filtro de "descarta quem já tem
parceiro" foi medido e é o que mais acelera — mas não está aplicado, porque faria a view
mostrar só as pendências, e o objetivo é ver o dia inteiro. A janela curta cobre o
desempenho.

Se ficar lenta, confira os hints e reduza a janela de dias.

---

## `02` — O botão

Ação Script na instância da view. Processa as **linhas selecionadas** na grade.

### Por que seleção obrigatória

Não existe `UPDATE` via script nesta instalação — nem `nativeUpdate`, nem `executeUpdate`,
nem `executeNative`. Gravar de volta na linha só funciona pelo objeto `linhas[L]`, que
exige linha marcada.

Acabou sendo melhor de operar: o usuário escolhe o que cadastrar, e nada acontece por
acidente.

### Fluxo por linha

```
1. lê o NUARQUIVO da linha e busca o XML na TGFIXN
2. recorta o bloco <dest>
3. decide quem é o parceiro: o lado que NÃO é a BeBaby
4. está na lista de exclusão? → ignora
5. o parceiro já existe? → registra e pula
6. localiza a cidade pelo código IBGE
7. resolve o endereço em três níveis
8. cria em TGFPAR
9. confirma no banco e limpa a divergência
```

Cada linha é isolada em `try/catch` — um XML problemático não derruba o lote.

### Como decide quem é o parceiro

O CNPJ da BeBaby sai das **posições 7–20 da própria chave de acesso**. O parceiro é o lado
oposto:

```javascript
var cnpjEmitente = chave.substring(6, 20);
var ehEmitenteBebaby = (soDigitos(docEmit) === cnpjEmitente);
var blocoParceiro = ehEmitenteBebaby ? bDest : bEmit;
```

Funciona para as duas empresas do grupo sem configuração. Quando o parceiro é o emitente,
o endereço vem de `<enderEmit>` em vez de `<enderDest>`.

⚠️ Esse ramo **nunca executou**: em 98 documentos analisados a BeBaby era sempre a
emitente.

### O endereço em três níveis

| Nível | Fonte | O que faz |
|---|---|---|
| 1 | `TSICEP` | consulta. Traz `CODCID` + `CODBAI` + `CODEND` já vinculados |
| 2 | ViaCEP | cria logradouro e bairro, e **grava o resultado na `TSICEP`** |
| 3 | — | só a cidade: `CODEND = 0`, `CODBAI = 0` |

O nível 2 alimenta o cache: o próximo cliente da mesma região cai no nível 1 e nem chama o
serviço. A cobertura melhora sozinha com o uso.

A URL vem do parâmetro `URLWSVIACEP` da `TSIPAR` (a coluna de chave é `CHAVE`, não
`NOMEPARAMETRO`), com fallback no código.

### Bairro e logradouro

Busca por nome antes de criar. O Sankhya **valida duplicata de bairro**
(`CORE_E00959: Já existe um bairro cadastrado com o nome X`) — logo, é catálogo global
compartilhado entre cidades, por design.

"CENTRO" usa o `CODBAI` genérico **866**, para não depender da grafia cadastrada.

O `CODREG` do bairro novo vem da cidade.

### A normalização

Tudo que vai para o banco passa por `normaliza()`: **caixa alta, sem acento, sem caractere
especial**.

É necessário porque as três fontes divergem:

| Fonte | Como manda |
|---|---|
| XML da NF-e | `Jardim Santo Antonio` (sem acento) |
| ViaCEP | `Jardim Santo Antônio` (com acento) |
| Marketplace | `Gon&ccedil;alves` (entidade HTML) |

Sem normalizar, a `TSIBAI` acumularia três grafias do mesmo bairro — e **não há `DELETE`**
disponível para limpar.

A função também decodifica entidades HTML (numéricas e nomeadas) antes de tirar os acentos.
Mantém ponto, hífen, barra, vírgula, parênteses e `&`, porque `EBAZAR.COM.BR LTDA` sem eles
viraria `EBAZAR COM BR LTDA`.

### Os campos do parceiro

Dos **67 campos `NOT NULL`** da `TGFPAR`, **62 têm `DEFAULT` no banco** e os defaults já
servem para consumidor final. O script informa só o que importa.

| Campo | Valor |
|---|---|
| `CODPARC` | `MAX(CODPARC) + 1` |
| `NOMEPARC` / `RAZAOSOCIAL` | `<xNome>` normalizado |
| `TIPPESSOA` | `F` (CPF) ou `J` (CNPJ) |
| `CGC_CPF` | só dígitos |
| **`CLIENTE`** | **`'S'` explícito** |
| `CODEND` / `CODBAI` / `CODCID` | do endereço resolvido |
| `NUMEND` / `COMPLEMENTO` / `CEP` | do XML |
| `CODPARCMATRIZ` | o próprio `CODPARC` |
| `DTCAD` / `DTALTER` | `new Date()` |

**⚠️ O `CLIENTE` é a única exceção aos defaults.** O default do dicionário do Sankhya
(`'N'`) vence o do banco (`'S'`), e parceiro com `CLIENTE = 'N'` não satisfaz o "cliente
ativo" que o motor exige. Comprovado: os parceiros 58773–58775 nasceram com `N` antes da
correção.

### A lista de exclusão

Por **raiz de CNPJ** (8 dígitos), para cobrir qualquer filial:

```javascript
var NAO_CADASTRAR = {
    "28414558": "BeBaby (empresas 1 e 2)",
    "15436940": "Amazon Servicos de Varejo (todas as filiais)",
    "03007331": "EBAZAR (Mercado Livre)"
};
```

São parceiros corporativos que exigem cadastro manual com IE, condição de pagamento e tipo
de parceiro — dados que o XML não traz. A Amazon tem 8 filiais cadastradas com
configurações diferentes entre si.

⚠️ Sem essa lista, o botão cadastrou por engano o `CODPARC 58783` (Amazon) em 11/09.

### Os interruptores

| Variável | Padrão | O que faz |
|---|---|---|
| `MODO_SIMULACAO` | `true` | só relata, não grava. **Comece assim** |
| `USAR_TSICEP` | `true` | nível 1 do endereço |
| `USAR_VIACEP` | `true` | nível 2. **Cria registros** em `TSIEND`, `TSIBAI`, `TSICEP` |
| `LIMPAR_DIVERG` | **`false`** | apaga a mensagem. Desligado — ver abaixo |
| `CODBAI_CENTRO` | `866` | `CODBAI` genérico de "CENTRO" |
| `MAX_LINHAS` | `10` | teto por clique |
| `TENTATIVAS_PK` | `3` | retentativas se o `CODPARC` colidir |

### O relatório

```
CADASTRO DE PARCEIROS
3 linha(s) selecionada(s)

  CRIADOS: 2   (com endereco: 1  |  sem endereco: 1)
  JA EXISTIAM: 1
  IGNORADOS POR REGRA: 0
  ERROS: 0
  DIVERGENCIAS LIMPAS: 2 nota(s)

COM ENDERECO COMPLETO:
   [112644] CODPARC 58782  MYRIAN LUND

SEM ENDERECO - completar manualmente na tela de Parceiros:
   [112631] CODPARC 58783  MARCIA NOBREGA  -  CEP 09230500
```

A view é somente leitura, então o resultado vem pela mensagem. As colunas `CADASTRADO` e
`ENDERECOOK` se atualizam ao recarregar a grade — são calculadas na consulta, não gravadas.

---

## `04` — A função de limpeza

A mensagem de divergência fica gravada na coluna `CONFIG` da `TGFIXN` desde o momento do
upload, e não é reavaliada enquanto a nota não processa.

### ⚠️ Vem desligada

`LIMPAR_DIVERG = false` por decisão de 12/09/2026: **quando a nota processa, o próprio
motor reescreve o `CONFIG` e o aviso some**. A limpeza só teria utilidade para nota que
nunca vai processar.

A função continua no repositório porque é útil em dois casos: limpar ruído acumulado de
notas antigas que não vão processar, e diagnosticar. Para ligar, basta
`LIMPAR_DIVERG = true` e criar a função no banco.

O que está abaixo descreve o funcionamento dela.

### Por que é função, e não `UPDATE` no script

Não existe `UPDATE` via script. Mas **função pode ser chamada de dentro de um `SELECT`** —
e `SELECT` o script faz:

```javascript
q.nativeSelect("SELECT STP_LIMPA_DIVERG_PARC({doc}) AS QTD FROM DUAL");
```

O `PRAGMA AUTONOMOUS_TRANSACTION` permite o `COMMIT` sem interferir na transação do script.

### O que ela remove

**Só a frase** do parceiro, não o bloco `<divDevolucao>` inteiro. O mesmo bloco pode conter
outras validações:

```
Tipo de Operação não informado em Outras Opções > Preferências...
Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF X.
```

Apagar o bloco levaria junto o aviso de Tipo de Operação, que é outro problema.

Quando a frase do parceiro é a **única** validação, a coluna fica vazia. O cabeçalho
`XML: nome-do-arquivo.xml` não conta como conteúdo — sem a frase ele fica órfão.

Validado contra os quatro formatos que existem na base:

| Situação | Resultado |
|---|---|
| Só a frase do parceiro | `CONFIG` vira `NULL` |
| Idem, com chave em vez de `.xml` no cabeçalho | `CONFIG` vira `NULL` |
| Duas validações, multilinha | mantém a outra |
| Duas validações em linha única (formato 2023) | mantém a outra |

### Quando o botão chama

Só depois de **confirmar no banco** que o parceiro existe com `CLIENTE = 'S'` e
`ATIVO = 'S'`. O `save()` ter passado não basta — apagar a divergência de um parceiro
inexistente esconderia um problema real.

Não limpa quando o parceiro já existia: nesse caso o botão não fez nada.

⚠️ Se a função não existir no banco, a chamada falha **em silêncio** e o cadastro segue.

### Limpa por documento, não por nota

A view agrupa: o `NUARQUIVO` exibido é a primeira nota daquele cliente. Se ele tiver três
notas pendentes, as três carregam a mesma frase.

---

## Decisões e o porquê

**Não cria cidade.** A base do Sankhya já vem com os municípios do IBGE. Se o `<cMun>` não
existir na `TSICID`, a linha falha com mensagem clara em vez de criar um município
inventado.

⚠️ A `TSICID` tem municípios **duplicados** — o mesmo `CODMUNFIS` em várias linhas. Por
isso `MIN(CODCID)` nos joins.

**Tudo sai do XML.** Nas notas de upload manual, as colunas `CHAVEACESSO`, `CNPJPARC`,
`CNPJDEST`, `CODEMP` e `CODTIPOPER` da `TGFIXN` vêm **nulas** — o Portal grava apenas `XML`
e `NOMEARQUIVO`.

**Parceiro sem endereço é comportamento correto**, não concessão: o parceiro 61662, criado
pela própria integração em produção, tem `CEP` preenchido e `CODEND = 0`.

**`CODPARC = MAX + 1`.** Não existe sequence. Há risco de colisão se alguém cadastrar pela
tela no mesmo instante — não corrompe nada, e o script tenta 3 vezes relendo o `MAX`.

**O banco não alcança a internet.** `UTL_HTTP` devolve `ORA-24247` (sem ACL de rede), tanto
para HTTPS quanto para HTTP. A aplicação tem rede; o Oracle não. Por isso a consulta ao
ViaCEP mora no script, não numa procedure.

---

## Limitações

- A view cobre os **últimos 2 dias**, só `STATUS = 0`. É a lista de trabalho do dia — para
  pendência antiga, altere `DHIMPORT` e meça o tempo depois
- **CEP geral de município não tem logradouro.** O ViaCEP devolve campos vazios (ex.:
  `87430000`, Tapejara/PR). Não é falha do serviço — nem a tela do Sankhya resolve esses
- **Nota importada por robô não tem `CONFIG`**: a divergência só é gravada quando o XML
  sobe pela tela do Portal. Por isso a view é mais confiável que o Portal para saber quem
  falta
- View é somente leitura: o resultado vem pela mensagem, não gravado na linha

### Não validado

| Item | Situação |
|---|---|
| Contraparte **pessoa jurídica** | um caso, e por engano (Amazon, antes da lista de exclusão) |
| Parceiro sendo o **emitente** | a BeBaby era sempre a emitente nos 98 documentos analisados |
| Nome acima de 80 caracteres | não houve caso. O script trunca sem erro |

---

## Diagnóstico rápido

**Em que base estou?**
```sql
SELECT MAX(CODPARC) FROM TGFPAR
```
O nome do banco e o servidor são iguais nos dois ambientes.

**A view está lenta?** Confira os hints `/*+ MATERIALIZE */` nas CTEs.

**O botão criou o parceiro mas não limpou a mensagem?**
```sql
SELECT OBJECT_NAME, STATUS FROM USER_OBJECTS
WHERE OBJECT_NAME = 'STP_LIMPA_DIVERG_PARC'
```
Se não retornar, a função não existe — a chamada falha em silêncio.

**Erro `X is not defined` no script?** Quase sempre é versão antiga colada na ação. Busque
no editor por uma constante recente, como `NAO_CADASTRAR`.

O arquivo `03-verificacao.sql` tem o conjunto completo de consultas.

---

## Segurança

Nenhum arquivo contém credenciais. O ViaCEP é público e não exige autenticação.
