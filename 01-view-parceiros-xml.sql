-- =====================================================================
-- AD_VWPARCXML
-- Lista de PARCEIROS a cadastrar a partir das notas do Portal de
-- Importacao de XML. Uma linha por documento (CNPJ/CPF), nao por nota.
--
-- Escopo: apenas ML FULL (empresa 1) e AMAZON FULL (empresa 2), notas
-- PENDENTES (STATUS = 0) dos ultimos 2 DIAS.
--
-- A view traz TUDO da janela -- cadastrados e nao cadastrados. A coluna
-- CADASTRADO distingue os dois.
--
-- A janela curta e deliberada: a view e a lista de trabalho do dia, nao
-- um historico. Para ver pendencia antiga, altere DHIMPORT abaixo -- mas
-- meça o tempo depois, porque o custo cresce rapido com o volume.
--
-- POR QUE TUDO SAI DO XML:
-- Nas notas subidas manualmente pelo Portal, as colunas CHAVEACESSO,
-- CNPJPARC, CNPJDEST, CODEMP, CODTIPOPER, XNOMEEMIT e XNOMEDEST ficam
-- NULAS -- o Portal grava apenas XML e NOMEARQUIVO (verificado nas notas
-- 112579-112584). A extracao do XML e a unica fonte confiavel.
--
-- ORIGEM pelo CNPJ do emitente (posicoes 7-20 da chave de acesso):
--   28414558000132 -> ML FULL       (empresa 1)
--   28414558000213 -> AMAZON FULL   (empresa 2)
--
-- MOTIVO DE EXISTIR:
-- O motor de importacao NAO cadastra o parceiro -- ele exige "parceiro
-- cliente ativo" e recusa a nota se nao achar. A divergencia aparece no
-- Portal como:
--   "Nao foi encontrado qualquer parceiro cliente ativo com o
--    CNPJ/CPF 05796562924"
-- Ou seja: cadastrar o parceiro e PRE-REQUISITO para a nota processar.
-- Atencao ao "cliente ativo": exige CLIENTE='S' E ATIVO='S'.
--
-- O Portal de Importacao de XML NAO ACEITA acoes de tela (confirmado
-- pelo Paulo em 09/09/2026). Esta view existe para ser publicada como
-- tela adicional, onde a acao de cadastro funciona.
--
-- NOMES SEM UNDERLINE: o Construtor de Telas nao aceita "_" no nome da
-- tabela nem dos campos. Como cada coluna da view vira um campo no
-- dicionario, os aliases expostos aqui sao todos sem underline
-- (NOMEXML, QTDNOTAS, ENDERECOOK, CIDADEOK). Os aliases internos das
-- CTEs podem ter underline -- nao sao expostos.
-- =====================================================================

CREATE OR REPLACE VIEW AD_VWPARCXML AS
WITH NOTAS AS (
    -- Extrai a chave e o bloco <dest> de cada nota.
    --
    -- O hint MATERIALIZE e ESSENCIAL. Sem ele o Oracle nao guarda o
    -- resultado da CTE: na hora do GROUP BY do AGRUPADO ele REAVALIA toda
    -- a cadeia de SUBSTR/INSTR sobre o CLOB, uma vez por coluna agregada.
    -- Sao nove MIN() -> nove releituras do XML por nota.
    --
    -- Foi isso, e nao o tipo de funcao de extracao, que custava 30s.
    -- Medicao que revelou (11/09/2026):
    --   CTE NOTAS isolada          =  0,5s
    --   + EXTRAIDO isolado         =  1,4s
    --   + AGRUPADO, SEM join algum = 30,1s   <- o GROUP BY reavaliando
    --   + join TGFPAR              = 40,8s
    --   + join TSICEP              = 46,4s
    --   + join TSICID              = 27,5s
    -- Os joins somam pouco: o custo ja estava no agrupamento.
    --
    -- DESEMPENHO -- os dois filtros sao essenciais (medido em 09/09/2026):
    --   sem filtro, 180 dias      = 16.912 notas -> nao termina
    --   STATUS = 0, sem data      = 12.195 notas -> ainda pesado
    --   STATUS = 0 + 90 dias      =    515 notas -> 21s (ainda pesado)
    --   + filtro por CNPJ do Full  =    395 notas
    --   + SUBSTR/INSTR no lugar do regex da chave -> NAO ajudou (30s)
    --
    -- O gargalo real era o REGEXP_REPLACE no join com a TGFPAR, que
    -- impedia o uso do indice TGFPAR_I03. Medicoes isolando cada etapa:
    --   extracao do XML (CTE NOTAS)      = 0,5s
    --   + EXTRAIDO (SUBSTR sobre o bloco) = 1,4s
    --   + os tres LEFT JOIN finais        = 30s  <- aqui
    --
    -- O custo real e o REGEXP sobre CLOB. Cada REGEXP_SUBSTR trocado por
    -- SUBSTR/INSTR economiza muito. Os que restam operam sobre o
    -- BLOCO_DEST (string curta), nao sobre o XML inteiro.
    -- Regex sobre CLOB e caro. Nao colocar INSTR(XML, ...) no WHERE:
    -- isso forca varredura do CLOB de TODAS as notas antes dos outros
    -- filtros. O descarte de nota sem <dest> acontece depois, pelo
    -- CHAVE IS NOT NULL e DOC_DEST IS NOT NULL.
    SELECT /*+ MATERIALIZE */
           X.NUARQUIVO,
           X.DHIMPORT,
           X.STATUS,
           X.CODUSUIMP,
           -- SUBSTR/INSTR em vez de REGEXP: regex sobre CLOB e MUITO
           -- mais caro. A chave tem 44 digitos fixos, entao a posicao
           -- basta -- nao precisa de expressao regular.
           TO_CHAR(SUBSTR(X.XML, INSTR(X.XML, '<chNFe>') + 7, 44))   AS CHAVE,
           -- Recorta EXATAMENTE de <dest> ate </dest>.
           -- Nao usar tamanho fixo: com SUBSTR(...,900) a janela passava
           -- do fechamento e misturava dados do bloco seguinte -- foi o
           -- que corrompeu a nota 109111 (CNPJ da Amazon com nome de
           -- pessoa fisica e municipio '----------').
           TO_CHAR(SUBSTR(X.XML,
                   INSTR(X.XML, '<dest>'),
                   INSTR(X.XML, '</dest>') - INSTR(X.XML, '<dest>') + 7))
                                                                  AS BLOCO_DEST
    FROM TGFIXN X
    WHERE X.STATUS = 0
      AND X.DHIMPORT >= SYSDATE - 2
      -- Descarta o que nao e do Full ANTES do regex. O NOMEARQUIVO traz
      -- a chave nas notas manuais; a CHAVEACESSO, nas que a integracao
      -- preencheu. Corta ~23% sem custo (medido: 515 -> 395).
      AND (X.NOMEARQUIVO LIKE '%2841455800%'
        OR X.CHAVEACESSO LIKE '______2841455800%')
      AND INSTR(X.XML, '</dest>') > INSTR(X.XML, '<dest>')
),
EXTRAIDO AS (
    SELECT /*+ MATERIALIZE */
           N.NUARQUIVO,
           N.DHIMPORT,
           N.STATUS,
           N.CODUSUIMP,
           N.CHAVE,
           SUBSTR(N.CHAVE, 7, 14) AS CNPJ_EMIT,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<xNome>') + 7,
                  INSTR(N.BLOCO_DEST, '</xNome>')
                      - INSTR(N.BLOCO_DEST, '<xNome>') - 7)     AS NOME_DEST,
           CASE WHEN INSTR(N.BLOCO_DEST, '<CNPJ>') > 0 THEN
                    SUBSTR(N.BLOCO_DEST,
                           INSTR(N.BLOCO_DEST, '<CNPJ>') + 6,
                           INSTR(N.BLOCO_DEST, '</CNPJ>')
                               - INSTR(N.BLOCO_DEST, '<CNPJ>') - 6)
                WHEN INSTR(N.BLOCO_DEST, '<CPF>') > 0 THEN
                    SUBSTR(N.BLOCO_DEST,
                           INSTR(N.BLOCO_DEST, '<CPF>') + 5,
                           INSTR(N.BLOCO_DEST, '</CPF>')
                               - INSTR(N.BLOCO_DEST, '<CPF>') - 5)
           END                                                   AS DOC_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<CEP>') + 5,
                  INSTR(N.BLOCO_DEST, '</CEP>')
                      - INSTR(N.BLOCO_DEST, '<CEP>') - 5)        AS CEP_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<cMun>') + 6,
                  INSTR(N.BLOCO_DEST, '</cMun>')
                      - INSTR(N.BLOCO_DEST, '<cMun>') - 6)       AS IBGE_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<xMun>') + 6,
                  INSTR(N.BLOCO_DEST, '</xMun>')
                      - INSTR(N.BLOCO_DEST, '<xMun>') - 6)       AS MUN_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<UF>') + 4,
                  INSTR(N.BLOCO_DEST, '</UF>')
                      - INSTR(N.BLOCO_DEST, '<UF>') - 4)         AS UF_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<xLgr>') + 6,
                  INSTR(N.BLOCO_DEST, '</xLgr>')
                      - INSTR(N.BLOCO_DEST, '<xLgr>') - 6)       AS LGR_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<nro>') + 5,
                  INSTR(N.BLOCO_DEST, '</nro>')
                      - INSTR(N.BLOCO_DEST, '<nro>') - 5)        AS NRO_DEST,
           SUBSTR(N.BLOCO_DEST,
                  INSTR(N.BLOCO_DEST, '<xBairro>') + 9,
                  INSTR(N.BLOCO_DEST, '</xBairro>')
                      - INSTR(N.BLOCO_DEST, '<xBairro>') - 9)    AS BAIRRO_DEST
    FROM NOTAS N
    WHERE N.CHAVE IS NOT NULL
),
DOFULL AS (
    -- So ML FULL e AMAZON FULL. Descarta a propria BeBaby como parceiro.
    SELECT /*+ MATERIALIZE */
           E.*,
           CASE E.CNPJ_EMIT
               WHEN '28414558000132' THEN 'ML FULL'
               WHEN '28414558000213' THEN 'AMAZON FULL'
           END AS ORIGEM
    FROM EXTRAIDO E
    WHERE E.CNPJ_EMIT IN ('28414558000132', '28414558000213')
      AND E.DOC_DEST IS NOT NULL
      AND SUBSTR(E.DOC_DEST, 1, 8) <> '28414558'   -- nunca a propria BeBaby
),
AGRUPADO AS (
    -- Uma linha por documento. O operador cadastra 1 parceiro, nao
    -- percorre N notas do mesmo cliente.
    SELECT /*+ MATERIALIZE */
           DOC_DEST,
           MIN(NUARQUIVO)  AS NUARQUIVO,      -- PK da view
           MIN(DHIMPORT)   AS DHIMPORT,       -- primeira aparicao
           MAX(DHIMPORT)   AS DHIMPORT_ULT,
           COUNT(*)        AS QTD_NOTAS,
           MIN(ORIGEM)     AS ORIGEM,
           MIN(NOME_DEST)  AS NOME_DEST,
           MIN(CEP_DEST)   AS CEP_DEST,
           MIN(IBGE_DEST)  AS IBGE_DEST,
           MIN(MUN_DEST)   AS MUN_DEST,
           MIN(UF_DEST)    AS UF_DEST,
           MIN(LGR_DEST)   AS LGR_DEST,
           MIN(NRO_DEST)   AS NRO_DEST,
           MIN(BAIRRO_DEST) AS BAIRRO_DEST
    FROM DOFULL
    GROUP BY DOC_DEST
)
SELECT
    A.NUARQUIVO,                                    -- PK
    A.ORIGEM,
    A.DHIMPORT,
    A.DOC_DEST                          AS DOCUMENTO,
    CASE WHEN LENGTH(A.DOC_DEST) > 11 THEN 'J' ELSE 'F' END AS TIPPESSOA,
    A.NOME_DEST                         AS NOMEXML,
    A.QTD_NOTAS      AS QTDNOTAS,   -- notas pendentes deste parceiro

    -- ---- ja cadastrado? exige CLIENTE ativo, como o motor exige
    CASE WHEN P.CODPARC IS NULL              THEN 'NAO'
         WHEN P.CLIENTE <> 'S'               THEN 'NAO E CLIENTE'
         WHEN P.ATIVO   <> 'S'               THEN 'INATIVO'
         ELSE 'SIM'
    END                                 AS CADASTRADO,

    -- Mesma informacao COLORIDA, para leitura na grade.
    -- Duas colunas de proposito: a de texto puro serve para FILTRAR
    -- (filtrar por 'NAO' numa coluna de HTML nao funciona), a colorida
    -- serve para o operador bater o olho.
    -- O campo no Construtor precisa de Apresentacao = Formatacao HTML.
    CASE WHEN P.CODPARC IS NULL THEN
           '<DIV STYLE="BACKGROUND-COLOR:#E57373;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>NAO CADASTRADO</B></SPAN></DIV>'
         WHEN P.CLIENTE <> 'S' THEN
           '<DIV STYLE="BACKGROUND-COLOR:#FFB74D;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>NAO E CLIENTE</B></SPAN></DIV>'
         WHEN P.ATIVO <> 'S' THEN
           '<DIV STYLE="BACKGROUND-COLOR:#FFF176;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>INATIVO</B></SPAN></DIV>'
         ELSE
           '<DIV STYLE="BACKGROUND-COLOR:#81C784;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>CADASTRADO</B></SPAN></DIV>'
    END                                 AS CADASTRADOCOR,

    P.CODPARC,
    P.NOMEPARC,
    P.CLIENTE,
    P.ATIVO,

    -- ---- endereco: diz o que FAZER, nao o que falta.
    -- 'DIGITAR CEP NA TELA' e o caso em que o CEP nao esta no cache da
    -- TSICEP, mas a tela de Parceiros resolve por caminho proprio (ver
    -- 03-fatos-apurados.md). Nao significa que o endereco e irrecuperavel.
    CASE WHEN P.CODPARC IS NOT NULL AND NVL(P.CODEND, 0) > 0 THEN 'SIM'
         WHEN P.CODPARC IS NOT NULL                          THEN 'FALTA ENDERECO'
         WHEN C.CODEND IS NOT NULL                           THEN 'AUTOMATICO'
         ELSE 'DIGITAR CEP NA TELA'
    END                                 AS ENDERECOOK,

    CASE WHEN P.CODPARC IS NOT NULL AND NVL(P.CODEND, 0) > 0 THEN
           '<DIV STYLE="BACKGROUND-COLOR:#81C784;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>COMPLETO</B></SPAN></DIV>'
         WHEN P.CODPARC IS NOT NULL THEN
           '<DIV STYLE="BACKGROUND-COLOR:#FFB74D;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>FALTA ENDERECO</B></SPAN></DIV>'
         WHEN C.CODEND IS NOT NULL THEN
           '<DIV STYLE="BACKGROUND-COLOR:#AED581;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>CACHE LOCAL</B></SPAN></DIV>'
         ELSE
           '<DIV STYLE="BACKGROUND-COLOR:#90CAF9;PADDING:2px;TEXT-ALIGN:CENTER;">'
           || '<SPAN STYLE="COLOR:#000000;"><B>VIA CEP</B></SPAN></DIV>'
    END                                 AS ENDERECOCOR,

    -- ---- dados do XML, para completar manualmente quando faltar
    A.CEP_DEST                          AS CEP,
    A.LGR_DEST                          AS LOGRADOURO,
    A.NRO_DEST                          AS NUMERO,
    A.BAIRRO_DEST                       AS BAIRRO,
    A.MUN_DEST                          AS MUNICIPIO,
    A.UF_DEST                           AS UF,
    CID.CODCID,
    CASE WHEN CID.CODCID IS NULL THEN 'NAO EXISTE NA TSICID' ELSE 'OK' END
                                        AS CIDADEOK
FROM AGRUPADO A
-- Mesmo cuidado na TGFPAR: se houver o mesmo documento em mais de um
-- parceiro, o join direto duplicaria a linha. Prioriza o que serve ao
-- motor: CLIENTE='S' e ATIVO='S'.
--
-- DESEMPENHO: NAO usar REGEXP_REPLACE no CGC_CPF. O campo nesta base
-- guarda SO DIGITOS (verificado: zero registros com mascara em 44 mil),
-- e existe indice TGFPAR_I03 sobre a coluna. O regex impedia o uso do
-- indice e forcava o calculo da expressao para todas as linhas -- era o
-- gargalo da view (30s -> ver medicao no topo).
LEFT JOIN (SELECT DOC, CODPARC, NOMEPARC, CLIENTE, ATIVO, CODEND
           FROM (SELECT CGC_CPF AS DOC,
                        CODPARC, NOMEPARC, CLIENTE, ATIVO, CODEND,
                        ROW_NUMBER() OVER (
                            PARTITION BY CGC_CPF
                            ORDER BY CASE WHEN CLIENTE = 'S' AND ATIVO = 'S'
                                          THEN 0 ELSE 1 END, CODPARC) AS RN
                 FROM TGFPAR WHERE CGC_CPF IS NOT NULL)
           WHERE RN = 1) P
       ON P.DOC = A.DOC_DEST
LEFT JOIN (SELECT CEP, MIN(CODEND) AS CODEND
           FROM TSICEP GROUP BY CEP) C
       ON C.CEP = A.CEP_DEST
-- A TSICID tem municipios DUPLICADOS: o mesmo CODMUNFIS aparece em
-- varias linhas com CODCID diferente (ex.: Bom Sucesso de Itarare com
-- 5730, 711 e 5824). Um join direto multiplicava as linhas da view e
-- quebrava a chave primaria. MIN(CODCID) resolve deterministicamente.
LEFT JOIN (SELECT CODMUNFIS, MIN(CODCID) AS CODCID
           FROM TSICID GROUP BY CODMUNFIS) CID
       ON CID.CODMUNFIS = A.IBGE_DEST
ORDER BY A.DHIMPORT
