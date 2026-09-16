# Contexto do projeto — para retomar em outra conversa

Cole este arquivo no início de um chat novo. Ele traz o estado atual, o que foi
descoberto, e o que não fazer.

**Última atualização:** 11/09/2026

**Estado:** ciclo completo validado em homologação. Notas processaram com o parceiro
criado pelo botão (`NUNOTA 193189` e `193190`), e a limpeza da divergência foi testada
contra os quatro formatos de mensagem que existem na base.

---

## 1. O problema

**Empresa:** BeBaby Group Importação Ltda. Marcas Kikkaboo e ABC Design.
**ERP:** Sankhya, banco Oracle.

As notas fiscais do Full (Mercado Livre e Amazon) sobem pelo **Portal de Importação de
XML**. O motor de importação do Sankhya exige **"parceiro cliente ativo"** e recusa a nota
se não encontrar — a divergência aparece no Portal como:

> Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF 03846853747.

Hoje alguém cadastra o cliente à mão, copiando os dados do XML. Foram ~90 cadastros
manuais em 90 dias, concentrados em lotes (33 numa única tarde).

**Confirmado por teste:** o motor **não** cria o parceiro. Ele localiza e falha. O
cadastro é pré-requisito para a nota processar.

---

## 2. O que foi construído

Uma tela sobre view que lista os parceiros faltantes, com um botão que cadastra a partir
do bloco `<dest>` do XML.

```
XML sobe pelo Portal (TGFIXN)
        ↓
view AD_VWPARCXML mostra quem falta cadastrar
        ↓
operador seleciona e clica em "Cadastrar Parceiros"
        ↓
script cria em TGFPAR, com endereço resolvido
        ↓
a nota passa a processar
```

**Validado em homologação (11/09/2026):** 13 parceiros criados, e duas notas processaram
com o parceiro criado pelo robô (`NUNOTA 193189` e `193190`, `CODPARC 58782` e `58794`).

### Arquivos

| Arquivo | O que é |
|---|---|
| `00-GUIA-PRODUCAO.md` | Passo a passo de implantação |
| `01-view-parceiros-xml.sql` | A view |
| `02-cadastrar-parceiros-view.js` | O botão |
| `03-verificacao.sql` | Queries de conferência |

---

## 3. Ambiente

| Item | Situação |
|---|---|
| **SQL Developer** (acesso direto) | DDL e DML completos |
| **DBExplorer** (dentro do Sankhya) | **somente SELECT** |
| **Script de ação** (JavaScript) | SELECT + `novaLinha`/`setCampo`/`save`; **sem UPDATE** |

**Teste de "em que base estou":** `SELECT MAX(CODPARC) FROM TGFPAR`.
Homologação ficava em ~58.700; produção em ~61.700. Nome do banco (`BEBABY`) e servidor
(`dborcl01`) são iguais nos dois.

### ⚠️ A homologação está com estrutura defasada

O clone tem colunas a menos que produção. Isso travou várias telas ao longo do projeto:

| Coluna faltante | O que travou |
|---|---|
| `TGFTOP->NFSETIPOPER` | Portal de Importação de XML |
| `TGFINDOPER->CARACFORNEC` e `LOCALFORNEC` | tela de Parceiros (criadas manualmente) |
| `TCSCON->TIPODEDUCAO` | botão "Validar importação" |

**Pendente com o Paulo:** rodar o update de estrutura em vez de criar coluna por coluna.

---

## 4. Fatos apurados — não redescobrir

### TGFPAR (parceiros)

**`CODPARC` não tem sequence.** É `MAX(CODPARC) + 1`. Verificado: em produção os códigos
criados pela integração são consecutivos.

**Dos 67 campos `NOT NULL`, 62 têm `DEFAULT` no banco**, e os defaults servem para
consumidor final (`FORNECEDOR='N'`, `ATIVO='S'`, `SIMPLES='N'`, `RETEM*='N'`,
`TEMIPI='S'`, `TIPOFATUR='L'`). Sem default só cinco: `CODPARC`, `NOMEPARC`, `TIPPESSOA`,
`DTCAD`, `DTALTER`.

**⚠️ `CLIENTE` é a única exceção.** O default do dicionário do Sankhya (`'N'`) vence o do
banco (`'S'`). Tem que ser informado explicitamente — parceiro com `CLIENTE='N'` não
satisfaz o "cliente ativo" que o motor exige. Comprovado: os parceiros 58773–58775
nasceram com `N` antes da correção.

**`novaLinha('Parceiro')` exige a PK informada.** Diferente da `TGFIXN`, onde é
autonumerada. O erro é `Elemento de um EntityPrimaryKey não pode ser nulo`, e acontece na
criação do objeto, antes de qualquer `setCampo`.

**`CODPARCMATRIZ` aponta para o próprio `CODPARC`** — o Sankhya resolve sozinho.

**`FORNECEDOR` não é requisito do motor.** Testado: das 20 notas que processaram com
`STATUS 5`, nove têm o parceiro com `FORNECEDOR = N`.

**`getUsuarioLogado()` não funciona** nesta instalação. O `CODUSU` fica 0.

### TSICID (cidades)

`CODMUNFIS` é o código IBGE. O XML traz `<cMun>` com esse código — **`cMun` ≠ `CODCID`**,
a tradução é obrigatória.

**⚠️ Há municípios duplicados:** o mesmo `CODMUNFIS` aparece em várias linhas com `CODCID`
diferente (Bom Sucesso de Itararé tem 5730, 711 e 5824). Join direto multiplica linhas —
usar `MIN(CODCID)`.

Nunca criar cidade: a base já vem com os municípios do IBGE.

### TSICEP (CEPs)

Mapeia `CEP` → `CODCID` + `CODBAI` + `CODEND`, **já vinculados entre si**.

**Não é a base dos Correios — é um cache alimentado por uso.** ~9.000 registros. A tela de
Parceiros busca por caminho próprio (serviço externo) e grava o resultado ali. Testado: de
10 CEPs, a tabela tinha 5 e a tela achou 9 — e **depois** da pesquisa manual, a tabela
passou a ter os 10.

A coluna `INTERVALO` é nula em 100% dos registros: não é tabela de faixas.

### TSIBAI (bairros) e TSIEND (logradouros)

**A `TSIBAI` não tem vínculo com cidade** — só `CODBAI`, `NOMEBAI`, `CODREG`.

Isso gerou uma conclusão errada que depois foi corrigida: eu evitava buscar bairro por
nome, temendo vincular o município errado. Mas **o Sankhya valida duplicata de bairro**
(`CORE_E00959: Já existe um bairro cadastrado com o nome X`). Logo, bairro é catálogo
**global, compartilhado entre cidades por design** — buscar por nome é o comportamento do
produto.

O `CODREG` do bairro novo vem da cidade (confirmado pelo Paulo).
"CENTRO" usa o `CODBAI` genérico **866**.

### ViaCEP

O Sankhya tem três provedores configurados na `TSIPAR` (a coluna de chave é **`CHAVE`**,
não `NOMEPARAMETRO`):

| Chave | Valor |
|---|---|
| `URLWSVIACEP` | `https://viacep.com.br/ws/` |
| `URLWSCORREIOS` | `http://buscacep.sankhya.com.br:33000/consultaCEP` |
| `TIPOCONSULTACEP` | `2` |

**O script de ação alcança o ViaCEP** (HTTP 200, testado). A resposta traz `ibge`, que casa
com `TSICID.CODMUNFIS`.

**⚠️ O BANCO não alcança a internet.** `UTL_HTTP` devolve `ORA-24247` (sem ACL de rede),
tanto para HTTPS quanto para HTTP. A aplicação Java tem rede; o Oracle não. **Por isso
procedure PL/SQL não é opção** para consultar CEP.

**Limite real:** CEP geral de município volta com `logradouro` e `bairro` vazios (ex.:
`87430000`, Tapejara/PR). Não é falha do serviço — nem a tela do Sankhya resolve esses.

### TGFIXN (Portal de Importação de XML)

**As colunas vêm NULAS no upload manual.** `CHAVEACESSO`, `CNPJPARC`, `CNPJDEST`,
`CODEMP`, `CODTIPOPER` — o Portal grava apenas `XML` e `NOMEARQUIVO`. **Tudo tem que sair
do XML.**

**A mensagem de divergência fica gravada na coluna `CONFIG`**, dentro de
`<validacoes><divDevolucao>`, desde o momento do upload. **Não é reavaliada** — cadastrar
o parceiro não limpa o texto, embora a nota passe a processar.

**Quando a nota processa, o motor reescreve o `CONFIG` e o aviso some sozinho** (info da
equipe, 12/09/2026). Por isso o botão vem com `LIMPAR_DIVERG = false`.

A função `STP_LIMPA_DIVERG_PARC` (arquivo `04`) existe e funciona, mas só é útil para nota
que nunca vai processar. Ela remove **só a frase** do parceiro, não o bloco — porque o mesmo
`<divDevolucao>` pode conter outras validações (a nota 109154 tem "Tipo de Operação não
informado" junto).

⚠️ Nota importada pelo **robô da Anymarket** não tem `CONFIG` preenchido — a divergência
só é gravada quando o XML sobe pela tela do Portal, que é onde a validação roda. Por isso
a view é mais confiável que o Portal para saber quem falta cadastrar.

Pendente de confirmar em produção: se um processamento completo reescreve o `CONFIG`.

**O Portal NÃO aceita ações de tela** (confirmado pelo Paulo). Por isso a funcionalidade
mora numa view, não no Portal.

### Identificação das empresas

O CNPJ do emitente sai das **posições 7–20 da chave de acesso**:

| CNPJ | Empresa |
|---|---|
| `28414558000132` | empresa 1 — **ML Full** |
| `28414558000213` | empresa 2 — **Amazon Full** |

Isso permite separar a origem sem configuração, e identificar qual lado da nota é a
BeBaby — o parceiro é sempre **o lado que não é ela**.

---

## 5. Decisões de projeto

**Não cria cidade.** Se o IBGE não existir na `TSICID`, a linha falha com mensagem clara.

**Lista de exclusão por raiz de CNPJ.** BeBaby, Amazon (`15436940`) e EBAZAR (`03007331`)
nunca são cadastradas. A Amazon tem 8 filiais com configurações diferentes entre si —
alguém gerencia isso à mão.

⚠️ Sem essa lista, o botão cadastrou por engano o `CODPARC 58783` (Amazon, CNPJ
`15436940003544`) em 11/09.

**Normalização.** Nomes vão para o banco em CAIXA ALTA, sem acento e sem caractere
especial. As fontes divergem: o XML vem sem acento, o ViaCEP vem com, e o marketplace às
vezes manda entidade HTML (`Gon&ccedil;alves`). Sem normalizar, a `TSIBAI` acumularia
várias grafias do mesmo bairro — e **não há `DELETE` disponível**.

**Endereço em três níveis:** `TSICEP` → ViaCEP (cria e alimenta o cache) → só a cidade
(`CODEND = 0`).

Endereço vazio **é o comportamento da própria integração**: o parceiro 61662, criado em
produção, tem `CEP` preenchido e `CODEND = 0`.

**Seleção obrigatória.** Não existe `UPDATE` via script nesta instalação
(`nativeUpdate`, `executeUpdate`, `executeNative` não existem). Gravar de volta na linha só
funciona pelo objeto `linhas[L].setCampo()`, que exige linha selecionada.

---

## 6. Armadilhas do Sankhya

### Construtor de Telas

**Não aceita underline** em nome de tabela nem de campo. Por isso as colunas da view são
`NOMEXML`, `QTDNOTAS`, `ENDERECOOK`.

**Não registra view que já existe** — dá `CORE_E03093`. A ordem é: cria tabela pelo
assistente → **"Transformar Tabela em View"** → substitui a definição no banco. A tabela é
destruída na conversão; nada fica armazenado.

**"Definir chave primária para a unidade de dados"** é obrigatório em view — ela não tem
constraint.

**Para alterar campo em tela que é view:** primeiro altera a view no banco, depois o
Construtor. A ordem inversa não funciona.

**Texto/Padrão = `VARCHAR(100)`.** Colunas que a view devolve como `VARCHAR2(4000)`
(resultado de `TO_CHAR` sobre CLOB) precisam de "Caixa de Texto".

**`CORE_E01922` ao ligar "Permite pesquisa?"** não é regra do produto — é sessão ou cache.
Sair e entrar no sistema resolve. (Cheguei a documentar como proibição; estava errado.)

### Scripts de ação (Rhino)

- **Sucesso:** `mensagem = "texto"` → não cancela a transação
- **Erro:** `throw "texto"` → **cancela a transação** (rollback). Nunca usar depois de gravar
- SELECT: `getQuery("native")`, placeholder é `{x}`, **não** `?`
- Quebra de linha na mensagem: `\n` funciona
- **Declaração de função dentro de bloco `{}` não sofre hoisting** — declarar no topo

### Erros comuns

| Erro | Causa |
|---|---|
| `Tipo esperado 'String', recebido 'java.math.BigDecimal'` | número onde a coluna é texto |
| `Propriedade 'X' com largura acima do limite` | valor maior que a coluna |
| `[object Object]` na mensagem | variável recebendo estrutura em vez de valor |
| `ORA-00936: expressão não encontrada` | vírgula órfã antes do `FROM` |
| `X is not defined` | quase sempre versão antiga colada na ação |
| Nota some da view sem erro | versão antiga da view no banco. O filtro `CHAVEACESSO LIKE '______2841455800%'` precisa de **seis** underscores (cUF + AAMM antes do CNPJ); com quatro, some silenciosamente o que vem de upload manual |
| "Selecione as notas..." com linha selecionada | falta permissão nos **campos**: o `getCampo()` falha e a lista fica vazia. São três níveis de acesso — tela, ação e campos (PERMITIDO + REPASSAR) |

---

## 7. A lição de desempenho

A view levava **30 segundos**. Três hipóteses minhas falharam antes de achar a causa:

1. regex sobre CLOB — troquei por `SUBSTR`/`INSTR`, **piorou** (30s → 32s)
2. `REGEXP_REPLACE` no join com `TGFPAR` — removi, **não mudou**
3. custo de ler o LOB — medido isolado: **0,4s**

O que resolveu foi **seccionar a consulta e medir etapa por etapa**:

| Etapa | Tempo |
|---|---|
| CTE `NOTAS` isolada | 0,5s |
| + `EXTRAIDO` | 1,4s |
| + `AGRUPADO`, **sem join algum** | **30,1s** |
| + os três `LEFT JOIN` | pouco a mais |

A causa: o Oracle não materializava a CTE. No `GROUP BY` com nove `MIN()`, ele
**reavaliava toda a cadeia de extração do XML uma vez por coluna agregada**.

A correção foi o hint `/*+ MATERIALIZE */` nas CTEs: **30s → 1,5s**.

**A lição:** medir a parte isolada não prova nada sobre o todo. Enquanto eu raciocinava
sobre o código, errei três vezes; quando medimos por seccionamento, foram quatro execuções
para achar.

---

## 8. Não validado

| Item | Situação |
|---|---|
| Contraparte **pessoa jurídica** (`TIPPESSOA = 'J'`) | um caso cadastrado, mas por engano (Amazon, antes da lista de exclusão) |
| Parceiro sendo o **emitente** | em 98 documentos a BeBaby era sempre a emitente; esse ramo nunca executou |
| Nome/razão social acima de 80 caracteres | não houve caso. O script trunca sem erro |
| Processamento completo da nota | em homologação gerou cabeçalho na `TGFCAB` mas **nenhum item na `TGFITE`**, e `VLRNOTA` zerado — provavelmente efeito das colunas faltantes |

---

## 9. Pendências

| # | Pendência | Com quem |
|---|---|---|
| 1 | Update de estrutura na homologação (4 colunas conhecidas faltando) | Paulo |
| 2 | ~~O `CONFIG` é reescrito quando a nota processa?~~ | ✅ **Sim** — confirmado 12/09. A função `04` fica desligada |
| 3 | Confirmar que o `CODBAI 866` é genérico em produção | query no `03-verificacao.sql` |
| 4 | Testar contraparte pessoa jurídica de verdade | — |
| 5 | Corrigir o `CODPARC 58783` (Amazon cadastrada por engano, em homologação) | — |

---

## 10. Como me pedir ajuda a partir daqui

Coisas que funcionam bem:

- **Colar a mensagem de erro inteira**, com o código (`CORE_Exxxxx`, `ORA-xxxxx`)
- **Mandar o resultado das queries**, não só dizer que rodou
- **Avisar em qual base** está (homologação ou produção)
- Ao trocar script, **conferir que a versão colada é a atual** — isso causou quatro
  falsos problemas ao longo do projeto

Coisas em que eu erro com frequência e você pode me cobrar:

- **Supor a causa em vez de medir.** Peça para isolar e medir antes de eu propor correção
- **Editar arquivo por substituição de texto sem revalidar o todo** — gerou vírgula órfã,
  variável não definida e função removida mas ainda chamada
- **Generalizar de uma amostra pequena.** Vários "fatos" que afirmei vieram de 2 ou 3
  casos e depois se mostraram errados
