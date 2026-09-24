-- =====================================================================
-- CONFERENCIA -- view e cadastro de parceiros
-- Todas sao SELECT. Seguras em producao.
-- =====================================================================

-- ---------------------------------------------------------------------
-- EM QUE BASE ESTOU?
-- O nome do banco e o servidor sao iguais nos dois ambientes. O MAX de
-- CODPARC e o indicador confiavel.
-- ---------------------------------------------------------------------
SELECT SYS_CONTEXT('USERENV','DB_NAME')  AS BANCO,
       (SELECT MAX(CODPARC) FROM TGFPAR) AS MAX_PARCEIRO
FROM DUAL;


-- ---------------------------------------------------------------------
-- QUE STATUS EXISTEM E O QUE SIGNIFICAM
--
-- A view pega STATUS 0 e 4. Rode isto depois de qualquer atualizacao do
-- Sankhya: o status em que a divergencia de parceiro chega JA MUDOU uma
-- vez (era 0, passou a 4 em 24/09/2026).
--
-- Observado em 24/09/2026, ultimos 30 dias:
--   0 = 814 notas, 280 sem parceiro  -> pendente
--   2 = 214 notas,   0 sem parceiro
--   3 = 124 notas, 124 sem parceiro  -> SIGNIFICADO DESCONHECIDO
--   4 =  41 notas,   9 sem parceiro  -> pendente com divergencia
--   5 = 2.249 notas, 0 sem parceiro  -> processada
--
-- O STATUS 3 vem com CONFIG, DETALHESIMPORTACAO, CODPARC e NUNOTA todos
-- VAZIOS -- nao da para inferir o que e. O nome aparece na lista do
-- filtro "Status" na tela do Portal. Se for outro estado de pendencia,
-- precisa entrar na view.
-- ---------------------------------------------------------------------
SELECT STATUS, COUNT(*) AS QTD,
       SUM(CASE WHEN CODPARC IS NULL THEN 1 ELSE 0 END) AS SEM_PARCEIRO,
       MIN(DHIMPORT) AS DE, MAX(DHIMPORT) AS ATE
FROM TGFIXN
WHERE DHIMPORT >= SYSDATE - 30
GROUP BY STATUS ORDER BY STATUS;

-- Onde a divergencia de parceiro esta gravada, por status.
-- A tag mudou: era <divDevolucao>, passou a <EmpParcTransp>.
SELECT STATUS,
       COUNT(*) AS QTD,
       SUM(CASE WHEN INSTR(CONFIG, 'divDevolucao')  > 0 THEN 1 ELSE 0 END) AS TAG_ANTIGA,
       SUM(CASE WHEN INSTR(CONFIG, 'EmpParcTransp') > 0 THEN 1 ELSE 0 END) AS TAG_NOVA,
       SUM(CASE WHEN CONFIG IS NULL THEN 1 ELSE 0 END)                     AS SEM_CONFIG
FROM TGFIXN
WHERE DHIMPORT >= SYSDATE - 30
GROUP BY STATUS ORDER BY STATUS;


-- ---------------------------------------------------------------------
-- A VIEW ESTA SAUDAVEL?
-- Tempo esperado: poucos segundos. Se passar de 30s, conferir os hints
-- /*+ MATERIALIZE */ nas CTEs.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS LINHAS FROM AD_VWPARCXML;

-- Nenhum NUARQUIVO pode repetir -- seria quebra de chave primaria
SELECT NUARQUIVO, COUNT(*) AS QTD
FROM AD_VWPARCXML GROUP BY NUARQUIVO HAVING COUNT(*) > 1;

-- As colunas batem com os campos do Construtor?
SELECT COLUMN_ID, COLUMN_NAME, DATA_TYPE, DATA_LENGTH
FROM USER_TAB_COLUMNS
WHERE TABLE_NAME = 'AD_VWPARCXML' ORDER BY COLUMN_ID;


-- ---------------------------------------------------------------------
-- LISTA DE TRABALHO -- quem falta cadastrar
-- ---------------------------------------------------------------------
SELECT NUARQUIVO, ORIGEM, DHIMPORT, NOMEXML, DOCUMENTO, TIPPESSOA,
       CADASTRADO, ENDERECOOK, QTDNOTAS, CEP, MUNICIPIO, UF
FROM AD_VWPARCXML
WHERE CADASTRADO <> 'SIM'
ORDER BY DHIMPORT;

-- Resumo por situacao
SELECT ORIGEM, CADASTRADO, COUNT(*) AS QTD, SUM(QTDNOTAS) AS NOTAS
FROM AD_VWPARCXML
GROUP BY ORIGEM, CADASTRADO
ORDER BY ORIGEM, CADASTRADO;


-- ---------------------------------------------------------------------
-- CONFERIR OS PARCEIROS CRIADOS HOJE
--
-- Esperado: CLIENTE = S, RAZAOSOCIAL maiuscula e sem acento,
-- CODCID correto, CODEND/CODBAI preenchidos quando o CEP resolveu.
-- ---------------------------------------------------------------------
SELECT P.CODPARC, P.NOMEPARC, P.RAZAOSOCIAL, P.CGC_CPF, P.TIPPESSOA,
       P.CLIENTE, P.ATIVO, P.BLOQUEAR,
       P.CODEND, E.NOMEEND,
       P.CODBAI, B.NOMEBAI,
       P.CODCID, C.NOMECID,
       P.NUMEND, P.COMPLEMENTO, P.CEP,
       P.DTCAD
FROM TGFPAR P
LEFT JOIN TSIEND E ON E.CODEND = P.CODEND
LEFT JOIN TSIBAI B ON B.CODBAI = P.CODBAI
LEFT JOIN TSICID C ON C.CODCID = P.CODCID
WHERE P.DTCAD >= TRUNC(SYSDATE)
ORDER BY P.CODPARC DESC;


-- ---------------------------------------------------------------------
-- COMPARAR COM UM PARCEIRO CRIADO PELA INTEGRACAO
-- Exportar e comparar coluna a coluna. Toda divergencia e um campo a
-- investigar. Foi assim que se descobriu o CLIENTE = 'N'.
-- ---------------------------------------------------------------------
SELECT * FROM TGFPAR WHERE CODPARC IN (
    /* um criado pelo botao */ 0,
    /* um criado pela integracao */ 0
);


-- ---------------------------------------------------------------------
-- DUPLICIDADE -- mesmo documento em mais de um parceiro
-- Se retornar algo, o dedup falhou em algum momento.
-- ---------------------------------------------------------------------
SELECT CGC_CPF, COUNT(*) AS QTD,
       LISTAGG(CODPARC, ', ') WITHIN GROUP (ORDER BY CODPARC) AS CODIGOS
FROM TGFPAR
WHERE CGC_CPF IS NOT NULL AND DTCAD >= SYSDATE - 30
GROUP BY CGC_CPF
HAVING COUNT(*) > 1;


-- ---------------------------------------------------------------------
-- POR QUE ESTA NOTA NAO APARECE NA VIEW?
--
-- Trocar o NUARQUIVO. Cada coluna corresponde a uma condicao da view:
--   STATUS       -> tem que ser 0 ou 4
--   DIAS         -> tem que ser <= 30
--   POR_NOME ou POR_CHAVE -> pelo menos um 'S'
--   TEM_DEST     -> 'S'
--   CNPJ_EMIT    -> 28414558000132 ou 28414558000213
--
-- Se tudo passar e a nota ainda nao aparecer, lembre que a view AGRUPA
-- POR DOCUMENTO: o NUARQUIVO exibido e o da nota MAIS ANTIGA daquele
-- cliente. Busque por DOCUMENTO, nao por NUARQUIVO.
-- ---------------------------------------------------------------------
SELECT NUARQUIVO, NUMNOTA, NOMEARQUIVO, STATUS, DHIMPORT, CODPARC,
       ROUND(SYSDATE - DHIMPORT, 2) AS DIAS,
       CASE WHEN NOMEARQUIVO LIKE '%2841455800%' THEN 'S' ELSE 'N' END AS POR_NOME,
       CASE WHEN SUBSTR(CHAVEACESSO, 7, 10) = '2841455800' THEN 'S' ELSE 'N' END AS POR_CHAVE,
       CASE WHEN INSTR(XML, '</dest>') > INSTR(XML, '<dest>') THEN 'S' ELSE 'N' END AS TEM_DEST,
       SUBSTR(TO_CHAR(SUBSTR(XML, INSTR(XML,'<chNFe>') + 7, 44)), 7, 14) AS CNPJ_EMIT
FROM TGFIXN WHERE NUARQUIVO = 0;


-- ---------------------------------------------------------------------
-- A NOTA PROCESSOU?
-- Trocar o NUARQUIVO. Esperado: STATUS 5, DHPROCESS, CODPARC e NUNOTA
-- preenchidos.
-- ---------------------------------------------------------------------
SELECT NUARQUIVO, NOMEARQUIVO, STATUS, DHIMPORT, DHPROCESS,
       CODPARC, NUNOTA, CODTIPOPER, VLRNOTA,
       TO_CHAR(SUBSTR(CONFIG, 1, 1000))             AS CONFIG_TXT,
       TO_CHAR(SUBSTR(DETALHESIMPORTACAO, 1, 1000)) AS DETALHE
FROM TGFIXN WHERE NUARQUIVO = 0;

-- A nota gerada esta amarrada ao parceiro certo?
SELECT C.NUNOTA, C.CODPARC, P.NOMEPARC, C.CODTIPOPER, C.VLRNOTA, C.DTNEG,
       (SELECT COUNT(*) FROM TGFITE I WHERE I.NUNOTA = C.NUNOTA) AS ITENS
FROM TGFCAB C
JOIN TGFPAR P ON P.CODPARC = C.CODPARC
WHERE C.NUNOTA IN (SELECT NUNOTA FROM TGFIXN WHERE NUARQUIVO = 0);


-- ---------------------------------------------------------------------
-- A MENSAGEM DE DIVERGENCIA SOBREVIVE AO PROCESSAMENTO?
--
-- A divergencia fica gravada em TGFIXN.CONFIG, dentro de
-- <validacoes><divDevolucao>, desde o momento do upload. Cadastrar o
-- parceiro NAO limpa o texto.
--
-- Se esta consulta retornar ZERO, o motor reescreve o CONFIG ao
-- processar com sucesso -- e nao ha nada a resolver.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS PROCESSADAS_COM_DIVERGENCIA
FROM TGFIXN
WHERE STATUS = 5
  AND UPPER(TO_CHAR(SUBSTR(CONFIG, 1, 4000))) LIKE '%NAO FOI ENCONTRADO%';


-- ---------------------------------------------------------------------
-- CONFIRMAR O CODBAI GENERICO DE "CENTRO"
-- Se CIDADES for alto, o codigo e usado como generico em varios
-- municipios -- que e a premissa da constante CODBAI_CENTRO no script.
-- ---------------------------------------------------------------------
SELECT B.CODBAI, B.NOMEBAI, B.CODREG,
       (SELECT COUNT(*)               FROM TSICEP C WHERE C.CODBAI = B.CODBAI) AS USOS,
       (SELECT COUNT(DISTINCT C.CODCID) FROM TSICEP C WHERE C.CODBAI = B.CODBAI) AS CIDADES
FROM TSIBAI B WHERE B.CODBAI = 866;


-- ---------------------------------------------------------------------
-- COBERTURA DA TSICEP
-- Nao e a base dos Correios: e um cache alimentado por uso. A tela de
-- Parceiros busca por caminho proprio e grava o resultado ali.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS TOTAL_CEPS FROM TSICEP;

-- Quantos dos CEPs pendentes ja estao no cache
SELECT COUNT(*) AS PENDENTES,
       SUM(CASE WHEN C.CEP IS NULL THEN 0 ELSE 1 END) AS NO_CACHE
FROM AD_VWPARCXML V
LEFT JOIN TSICEP C ON C.CEP = V.CEP
WHERE V.CADASTRADO <> 'SIM';


-- ---------------------------------------------------------------------
-- QUANTO TRABALHO MANUAL ISSO SUBSTITUI
-- Picos de dezenas de cadastros num dia sao o que o botao elimina.
-- ---------------------------------------------------------------------
SELECT TO_CHAR(DTCAD, 'YYYY-MM-DD') AS DIA, CODUSU, COUNT(*) AS PARCEIROS
FROM TGFPAR
WHERE DTCAD >= SYSDATE - 90
GROUP BY TO_CHAR(DTCAD, 'YYYY-MM-DD'), CODUSU
ORDER BY DIA DESC, PARCEIROS DESC;
