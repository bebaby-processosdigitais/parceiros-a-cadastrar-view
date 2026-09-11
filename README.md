# Cadastro automático de parceiros a partir do XML — Sankhya

Tela sobre view que lista os parceiros faltantes das notas do Full e um botão que os
cadastra na `TGFPAR`, extraindo os dados do bloco `<dest>` do XML.

**Estado:** validado em homologação em 11/09/2026. Pronto para produção.

---

## O problema

As notas do Full (Mercado Livre e Amazon) sobem pelo **Portal de Importação de XML**. O
motor de importação exige **parceiro cliente ativo** e recusa a nota se não encontrar:

> Não foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF 03846853747.

O motor **não** cria o parceiro — ele localiza e falha. Hoje alguém cadastra à mão,
copiando do XML. Foram ~90 cadastros manuais em 90 dias, em lotes (33 numa única tarde).

---

## Como funciona

```
XML sobe pelo Portal (TGFIXN)
        ↓
view AD_VWPARCXML mostra quem falta cadastrar
        ↓
operador seleciona as linhas e clica em "Cadastrar Parceiros"
        ↓
script lê o <dest> do XML e cria em TGFPAR
        ↓
a nota passa a processar
```

O endereço é resolvido em três níveis: cache local (`TSICEP`) → ViaCEP → só a cidade.

---

## Arquivos

| # | Arquivo | O que é |
|---|---|---|
| — | `CONTEXTO-PARA-NOVO-CHAT.md` | Todo o histórico e as descobertas. Leia se for retomar o projeto |
| 0 | `00-GUIA-PRODUCAO.md` | Passo a passo de implantação |
| 1 | `01-view-parceiros-xml.sql` | A view. Roda no banco |
| 2 | `02-cadastrar-parceiros-view.js` | O botão. Cola numa ação de tela |
| 3 | `03-verificacao.sql` | Queries de conferência |

---

## Por onde começar

**Para implantar:** `00-GUIA-PRODUCAO.md`, na ordem.

**Para entender as decisões:** `CONTEXTO-PARA-NOVO-CHAT.md`, seções 4 e 5.

**Para diagnosticar algo:** `03-verificacao.sql`.

---

## Pré-requisitos

- Acesso direto ao banco para `CREATE VIEW` — o DBExplorer do Sankhya é **somente leitura**
- Acesso ao Construtor de Telas
- Saída de rede da aplicação para `https://viacep.com.br` (o Sankhya já usa esse serviço)

---

## Decisões que valem saber antes de mexer

**`CLIENTE = 'S'` é informado explicitamente.** É o único dos 67 campos `NOT NULL` da
`TGFPAR` em que o default do dicionário do Sankhya (`'N'`) vence o do banco (`'S'`).
Parceiro com `CLIENTE = 'N'` não satisfaz o "cliente ativo" que o motor exige.

**Não cria cidade.** A base do Sankhya já vem com os municípios do IBGE. Se o `<cMun>` do
XML não existir na `TSICID`, a linha falha com mensagem clara.

**Bairro e logradouro: busca antes de criar.** O Sankhya valida duplicata de bairro
(`CORE_E00959`) — logo, é catálogo global compartilhado entre cidades, por design.

**Nomes normalizados** em caixa alta, sem acento e sem caractere especial. As fontes
divergem: o XML vem sem acento, o ViaCEP vem com, e o marketplace às vezes manda entidade
HTML (`Gon&ccedil;alves`). Sem normalizar, a `TSIBAI` acumularia várias grafias do mesmo
bairro — e **não há `DELETE` disponível** para limpar.

**Lista de exclusão por raiz de CNPJ.** BeBaby, Amazon e EBAZAR nunca são cadastradas —
são parceiros corporativos que exigem cadastro manual.

**Parceiro sem endereço é comportamento correto**, não concessão: o parceiro 61662, criado
pela própria integração em produção, tem `CEP` preenchido e `CODEND = 0`.

---

## Duas coisas que economizam tempo

**Em que base estou?** `SELECT MAX(CODPARC) FROM TGFPAR` — o nome do banco e o servidor
são iguais nos dois ambientes.

**Se a view demorar mais de 30 segundos**, confirme os hints `/*+ MATERIALIZE */` nas
CTEs. Sem eles o Oracle reavalia a extração do XML uma vez por coluna agregada: 30s contra
1,5s.

---

## Limitações conhecidas

- A view cobre os últimos **90 dias**, só `STATUS = 0` — é ajuste de desempenho
- CEP geral de município não tem logradouro; o parceiro nasce só com a cidade
- A mensagem de divergência fica gravada na coluna `CONFIG` da `TGFIXN` e **não se apaga
  sozinha** ao cadastrar o parceiro — embora a nota passe a processar
- View é somente leitura: o resultado vem pela mensagem, não gravado na linha

---

## Segurança

Nenhum arquivo contém credenciais. O ViaCEP é público e não exige autenticação.
