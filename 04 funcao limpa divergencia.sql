-- =====================================================================
-- STP_LIMPA_DIVERG_PARC
--
-- Remove da coluna TGFIXN.CONFIG apenas a FRASE
--   "Nao foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF X"
-- das notas pendentes daquele documento.
--
-- ---------------------------------------------------------------------
-- POR QUE A FRASE E NAO O BLOCO <divDevolucao>
--
-- Uma versao anterior removia o bloco inteiro. Estava ERRADA: o mesmo
-- <divDevolucao> pode conter VARIAS validacoes. Exemplo real da nota
-- 109154 (homologacao):
--
--   <divDevolucao><![CDATA[
--   Tipo de Operacao nao informado em Outras Opcoes > Preferencias...
--   Nao foi encontrado qualquer parceiro cliente ativo com o CNPJ/CPF X.
--   ]]></divDevolucao>
--
-- Apagar o bloco levaria junto o aviso de Tipo de Operacao, que e outro
-- problema real e nao resolvido.
--
-- Esta versao recorta so a sentenca: do inicio da linha (ou do ponto
-- final anterior) ate o ponto que fecha a frase. Se depois disso o CONFIG
-- ficar sem conteudo util, a coluna vira NULL.
--
-- "Conteudo util" desconsidera o cabecalho "XML: nome-do-arquivo.xml",
-- que abre toda mensagem. Sem a frase do parceiro ele fica orfo e nao diz
-- nada -- entao a coluna tambem vira NULL nesse caso.
--
-- ---------------------------------------------------------------------
-- POR QUE UMA FUNCAO E NAO UM UPDATE DIRETO
--
-- Nao existe UPDATE via script de acao nesta instalacao: nem
-- nativeUpdate, nem executeUpdate, nem executeNative. Funcao, porem,
-- pode ser chamada de dentro de um SELECT -- e SELECT o script faz.
--
-- O PRAGMA AUTONOMOUS_TRANSACTION permite o COMMIT dentro da funcao sem
-- interferir na transacao do script que a chamou.
--
-- ---------------------------------------------------------------------
-- POR QUE POR DOCUMENTO E NAO POR NUARQUIVO
--
-- A view AD_VWPARCXML agrupa por documento: o NUARQUIVO exibido e apenas
-- a PRIMEIRA nota daquele cliente. Se ele tiver tres notas pendentes, as
-- tres carregam a mesma frase.
--
-- ---------------------------------------------------------------------
-- POR QUE INSTR/SUBSTR E NAO REGEXP
--
-- O texto tem acento ("Nao foi encontrado"), e o comportamento de REGEXP
-- com acento sobre CLOB depende do charset da sessao. O recorte por
-- posicao e previsivel, e o criterio de busca usa so a parte sem acento
-- da frase.
-- =====================================================================

-- =====================================================================
-- ⚠️ DESATUALIZADA -- LER ANTES DE USAR (24/09/2026)
--
-- Esta funcao foi escrita quando a divergencia chegava com STATUS = 0 e
-- dentro da tag <divDevolucao>. Duas coisas mudaram:
--
--   STATUS: agora chega com 4 (a view ja foi ajustada para 0 e 4)
--   TAG:    agora e <EmpParcTransp>, nao <divDevolucao>
--
-- Exemplo do formato novo, nota 120191:
--   <validacoes>
--     <EmpParcTransp>
--       <msg>-Nao foi encontrado qualquer parceiro cliente ativo
--            com o CNPJ/CPF 36256153049.</msg>
--     </EmpParcTransp>
--   </validacoes>
--
-- Para religar a funcao seria preciso:
--   1. trocar STATUS = 0 por STATUS IN (0, 4) no cursor
--   2. tratar as DUAS tags (notas antigas ainda tem <divDevolucao>)
--   3. testar de novo contra os formatos que existem na base
--
-- Como o botao vem com LIMPAR_DIVERG = false -- o motor reescreve o
-- CONFIG ao processar e o aviso some sozinho --, isso nao foi feito.
-- =====================================================================

CREATE OR REPLACE FUNCTION STP_LIMPA_DIVERG_PARC (P_DOCUMENTO IN VARCHAR2)
RETURN NUMBER
IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    V_AFETADAS  NUMBER := 0;
    V_CONFIG    CLOB;
    V_NOVO      CLOB;
    V_ANTES     CLOB;
    V_POS       NUMBER;
    V_INI       NUMBER;
    V_FIM       NUMBER;
    V_RESIDUO   VARCHAR2(4000);
    V_SEM_CAB   VARCHAR2(4000);
    V_AUX       NUMBER;

    CURSOR C_NOTAS IS
        SELECT NUARQUIVO, CONFIG
        FROM TGFIXN
        WHERE STATUS = 0
          AND CONFIG IS NOT NULL
          AND INSTR(CONFIG, P_DOCUMENTO) > 0
          AND INSTR(CONFIG, 'foi encontrado qualquer parceiro') > 0
        FOR UPDATE;

BEGIN
    IF P_DOCUMENTO IS NULL OR LENGTH(TRIM(P_DOCUMENTO)) = 0 THEN
        ROLLBACK;
        RETURN 0;
    END IF;

    FOR R IN C_NOTAS LOOP
        V_CONFIG := R.CONFIG;

        -- Onde comeca a frase (busca sem acento, por seguranca de charset)
        V_POS := INSTR(V_CONFIG, 'foi encontrado qualquer parceiro');

        IF V_POS > 0 THEN

            -- ---- inicio do recorte
            -- Volta ate a quebra de linha anterior; se nao houver, ate o
            -- ponto final da frase anterior; se nao houver, ate o inicio.
            V_ANTES := SUBSTR(V_CONFIG, 1, V_POS - 1);

            V_INI := INSTR(V_ANTES, CHR(10), -1, 1);
            IF V_INI = 0 THEN
                V_INI := INSTR(V_ANTES, '.', -1, 1);
            END IF;
            IF V_INI IS NULL THEN
                V_INI := 0;
            END IF;

            -- ---- fim do recorte: o ponto que fecha a frase
            V_FIM := INSTR(V_CONFIG, '.', V_POS);
            IF V_FIM = 0 THEN
                V_FIM := LENGTH(V_CONFIG);
            END IF;

            V_NOVO := SUBSTR(V_CONFIG, 1, V_INI)
                   || SUBSTR(V_CONFIG, V_FIM + 1);

            -- ---- sobrou so o cabecalho "XML: nome-do-arquivo"?
            -- Essa linha e o cabecalho da mensagem, nao uma validacao
            -- separada. Sem a frase do parceiro ela fica orfa e nao diz
            -- nada -- entao tambem sai.
            V_RESIDUO := TO_CHAR(SUBSTR(V_NOVO, 1, 4000));
            V_RESIDUO := REPLACE(V_RESIDUO, '<validacoes>',    '');
            V_RESIDUO := REPLACE(V_RESIDUO, '</validacoes>',   '');
            V_RESIDUO := REPLACE(V_RESIDUO, '<divDevolucao>',  '');
            V_RESIDUO := REPLACE(V_RESIDUO, '</divDevolucao>', '');
            V_RESIDUO := REPLACE(V_RESIDUO, '<![CDATA[',       '');
            V_RESIDUO := REPLACE(V_RESIDUO, ']]>',             '');
            V_RESIDUO := REPLACE(V_RESIDUO, CHR(10), ' ');
            V_RESIDUO := REPLACE(V_RESIDUO, CHR(13), ' ');
            V_RESIDUO := TRIM(V_RESIDUO);

            -- Tira o cabecalho: "XML: <qualquer coisa>.xml" ou
            -- "XML: <chave de 44 digitos> VDA". Se sobrar so isso, a
            -- coluna nao tem mais informacao.
            V_SEM_CAB := V_RESIDUO;
            IF INSTR(UPPER(V_SEM_CAB), 'XML:') = 1 THEN
                V_AUX := INSTR(UPPER(V_SEM_CAB), '.XML');
                IF V_AUX > 0 THEN
                    V_SEM_CAB := TRIM(SUBSTR(V_SEM_CAB, V_AUX + 4));
                ELSE
                    -- sem extensao: corta ate o primeiro espaco duplo ou
                    -- ate o fim da primeira "palavra longa" (a chave)
                    V_AUX := INSTR(V_SEM_CAB, ' ', 1, 3);
                    IF V_AUX > 0 THEN
                        V_SEM_CAB := TRIM(SUBSTR(V_SEM_CAB, V_AUX));
                    ELSE
                        V_SEM_CAB := NULL;
                    END IF;
                END IF;
            END IF;

            IF V_SEM_CAB IS NULL OR LENGTH(TRIM(V_SEM_CAB)) = 0 THEN
                V_NOVO := NULL;
            END IF;

            UPDATE TGFIXN SET CONFIG = V_NOVO
            WHERE NUARQUIVO = R.NUARQUIVO;

            V_AFETADAS := V_AFETADAS + 1;
        END IF;
    END LOOP;

    COMMIT;
    RETURN V_AFETADAS;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RETURN -1;   -- o script trata como "nao limpou", sem abortar
END STP_LIMPA_DIVERG_PARC;
/


-- =====================================================================
-- TESTE
--
-- Rodar no SQL Developer com F5 (Run Script) -- a barra que fecha o bloco
-- PL/SQL nao funciona com Ctrl+Enter.
-- =====================================================================

-- 1) A funcao compilou?
-- SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS
-- WHERE OBJECT_NAME = 'STP_LIMPA_DIVERG_PARC';

-- 2) O antes
-- SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 800)) AS CONFIG_TXT
-- FROM TGFIXN
-- WHERE STATUS = 0 AND INSTR(CONFIG, '03846853747') > 0;

-- 3) Limpar
-- SELECT STP_LIMPA_DIVERG_PARC('03846853747') AS NOTAS_LIMPAS FROM DUAL;

-- 4) O depois
-- SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 800)) AS CONFIG_TXT
-- FROM TGFIXN WHERE NUARQUIVO IN (/* os da consulta 2 */);


-- =====================================================================
-- TESTE DO CASO DIFICIL -- FACA ESTE
--
-- A nota 109154 tem DUAS validacoes no mesmo bloco. Depois de limpar, o
-- aviso de "Tipo de Operacao nao informado" TEM QUE PERMANECER.
-- Se ele sumir, a funcao esta removendo demais.
--
-- SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 800)) FROM TGFIXN
-- WHERE NUARQUIVO = 109154;
--
-- SELECT STP_LIMPA_DIVERG_PARC('15436940001177') FROM DUAL;
--
-- SELECT NUARQUIVO, TO_CHAR(SUBSTR(CONFIG, 1, 800)) FROM TGFIXN
-- WHERE NUARQUIVO = 109154;
-- =====================================================================

-- Retorno da funcao:
--   >= 0  quantidade de notas limpas
--   -1    erro (o script ignora e segue)
