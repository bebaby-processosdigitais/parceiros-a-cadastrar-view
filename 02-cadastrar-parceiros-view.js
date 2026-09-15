// =====================================================================
// BOTAO -- "Cadastrar Parceiros"
// Acao Script na view AD_VWPARCXML ("Parceiros a Cadastrar (XML)")
//
// Para cada linha SELECIONADA na grade: le o NUARQUIVO, busca o XML na
// TGFIXN, verifica se o parceiro existe na TGFPAR e, se nao existir,
// cadastra a partir do bloco <dest> do XML.
//
// A view AGRUPA POR DOCUMENTO: o NUARQUIVO e a primeira nota daquele
// cliente. O XML dela serve, porque o <dest> e o mesmo em todas as notas
// do mesmo parceiro.
//
// A view e SOMENTE LEITURA -- nao ha onde gravar resultado. O retorno vem
// pela mensagem, e as colunas CADASTRADO / ENDERECOOK se atualizam ao
// recarregar a grade (sao calculadas na consulta).
//
// COMECE COM MODO_SIMULACAO = true. Ele relata o que FARIA, sem gravar.
//
// Fatos apurados em 09/09/2026 que sustentam este script:
//   - CODPARC nao tem sequence: a numeracao e MAX(CODPARC)+1 (consecutiva
//     em producao: 61655..61670)
//   - Dos 67 campos NOT NULL da TGFPAR, 62 tem DEFAULT no banco e os
//     defaults ja servem para consumidor final (CLIENTE='S',
//     FORNECEDOR='N', ATIVO='S', SIMPLES='N', RETEM*='N')
//   - Sem default, so 5: CODPARC, NOMEPARC, TIPPESSOA, DTCAD, DTALTER
//   - CODEND / CODBAI / CODCID tem DEFAULT 0 -> endereco e OPCIONAL
//     (o parceiro 61662, criado pela propria integracao, tem CODEND=0)
//   - TSICID.CODMUNFIS e a coluna do codigo IBGE
//   - TSICEP mapeia CEP -> CODCID + CODBAI + CODEND ja vinculados. NAO e
//     a base dos Correios: e um CACHE alimentado por uso. A tela de
//     Parceiros busca por caminho proprio e grava o resultado ali.
//     Cobertura observada em producao: ~5 de 10 CEPs.
//   - Busca de bairro/endereco POR NOME foi ABANDONADA: o CODBAI 3934 e
//     "CENTRO", e existe em toda cidade. Vincular bairro da cidade errada
//     e pior que deixar sem bairro.
//   - O ViaCEP responde de dentro do Sankhya (HTTP 200, testado 10/09) e a
//     URL esta no parametro URLWSVIACEP da TSIPAR. O BANCO nao alcanca a
//     internet (UTL_HTTP da ORA-24247), mas o script de acao alcanca.
//   - CEP geral de municipio volta do ViaCEP com logradouro e bairro
//     VAZIOS (ex.: 87430000, Tapejara/PR). Nao e falha do servico -- e a
//     natureza do CEP. Nesses casos nem a tela do Sankhya resolve.
//   - Bairro "CENTRO" usa o CODBAI generico 866 (decisao do Paulo,
//     10/09). Qualquer outro nome cria bairro novo com o CODREG da
//     cidade. Aceita-se duplicata em troca de nunca vincular errado.
//   - O <dest> do marketplace NAO traz email nem telefone (0 de 10 XMLs)
//   - O Portal de Importacao de XML NAO aceita acoes de tela (Paulo,
//     09/09). Por isso a view existe: e nela que a acao funciona.
//   - Nao existe UPDATE via script nesta instalacao, e view nao aceita
//     gravacao. As colunas CADASTRADO / ENDERECOOK da view sao
//     calculadas na consulta, entao refletem o resultado ao recarregar.
// =====================================================================

// ========================================================== INTERRUPTORES
var MODO_SIMULACAO  = true;    // true = so relata, NAO grava
var LIMPAR_DIVERG   = false;   // DESLIGADO por decisao (12/09/2026):
                               // quando a nota processa, o proprio motor
                               // reescreve o CONFIG e o aviso some
                               // sozinho. A limpeza so teria utilidade
                               // para nota que nunca vai processar.
                               //
                               // Se ligar, remove do TGFIXN.CONFIG a
                               // mensagem "nao foi encontrado qualquer
                               // parceiro cliente ativo".
                               // REQUER a funcao STP_LIMPA_DIVERG_PARC
                               // criada no banco -- ver o arquivo
                               // 04-funcao-limpa-divergencia.sql.
                               // Se a funcao nao existir, a chamada falha
                               // em silencio e o cadastro segue normal.
// Endereco em tres niveis, do mais confiavel ao menos:
//   1. TSICEP  -- codigos ja vinculados entre si. Risco zero.
//   2. ViaCEP  -- devolve NOMES; criamos logradouro e bairro, e gravamos
//                 o resultado na TSICEP para alimentar o cache.
//   3. so a cidade -- CODEND=0 / CODBAI=0, como a propria integracao faz
//                 (o parceiro 61662, criado em producao, esta assim).
var USAR_TSICEP     = true;    // nivel 1
var USAR_VIACEP     = true;    // nivel 2 -- CRIA registros em TSIEND,
                               // TSIBAI e TSICEP. Desligue se quiser
                               // apenas consultar.
var CODBAI_CENTRO   = 866;     // CODBAI generico para "CENTRO"

// Raizes de CNPJ (8 digitos) que o botao NUNCA cadastra.
// A propria BeBaby, e parceiros corporativos que exigem cadastro manual
// com IE, condicao de pagamento e tipo de parceiro -- dados que o XML nao
// traz. A Amazon tem 8 filiais cadastradas, cada CD com CNPJ proprio e
// configuracoes DIFERENTES entre si (CLIENTE e ATIVO variam). Alguem
// gerencia isso a mao: nao e terreno para automacao.
//
// Sem esta lista, o botao cadastrou por engano o CODPARC 58783
// (AMAZON SERVICOS DE VAREJO, CNPJ 15436940003544) em 11/09/2026.
var NAO_CADASTRAR = {
    "28414558": "BeBaby (empresas 1 e 2)",
    "15436940": "Amazon Servicos de Varejo (todas as filiais)",
    "03007331": "EBAZAR (Mercado Livre)"
};
var URL_VIACEP      = "https://viacep.com.br/ws/";   // fallback do parametro
var MAX_LINHAS      = 10;      // teto por clique
var TENTATIVAS_PK   = 3;       // retentativas em caso de PK duplicada

// ------------------------------------------------------------ UTILITARIOS
function extrai(texto, tag) {
    var abre = "<" + tag + ">", fecha = "</" + tag + ">";
    var ini = texto.indexOf(abre);
    if (ini < 0) return null;
    ini += abre.length;
    var fim = texto.indexOf(fecha, ini);
    return (fim < 0) ? null : texto.substring(ini, fim);
}
function bloco(texto, tag) {
    var abre = "<" + tag + ">", fecha = "</" + tag + ">";
    var ini = texto.indexOf(abre);
    if (ini < 0) return "";
    var fim = texto.indexOf(fecha, ini);
    return (fim < 0) ? "" : texto.substring(ini, fim + fecha.length);
}
function corta(txt, max) {
    if (txt == null) return null;
    txt = String(txt);
    return (txt.length > max) ? txt.substring(0, max) : txt;
}
// Decodifica entidades HTML. O XML do marketplace as vezes traz o nome
// ja codificado -- vistos nos dados: "Gon&ccedil;alves" e
// "Ant&ocirc;nio Frederico Ozana". Sem decodificar, isso vai literal
// para a TGFPAR.
function decodificaHtml(txt) {
    if (txt == null) return null;
    var s = String(txt);

    // numericas: &#231; e &#xE7;
    s = s.replace(/&#x([0-9A-Fa-f]+);/g, function (m, h) {
        return String.fromCharCode(parseInt(h, 16));
    });
    s = s.replace(/&#([0-9]+);/g, function (m, n) {
        return String.fromCharCode(parseInt(n, 10));
    });

    // nomeadas mais comuns em nome proprio e logradouro
    var ent = {
        "&aacute;":"\u00E1", "&agrave;":"\u00E0", "&acirc;":"\u00E2",
        "&atilde;":"\u00E3", "&auml;":"\u00E4",
        "&eacute;":"\u00E9", "&egrave;":"\u00E8", "&ecirc;":"\u00EA",
        "&euml;":"\u00EB",
        "&iacute;":"\u00ED", "&igrave;":"\u00EC", "&icirc;":"\u00EE",
        "&oacute;":"\u00F3", "&ograve;":"\u00F2", "&ocirc;":"\u00F4",
        "&otilde;":"\u00F5", "&ouml;":"\u00F6",
        "&uacute;":"\u00FA", "&ugrave;":"\u00F9", "&ucirc;":"\u00FB",
        "&uuml;":"\u00FC",
        "&ccedil;":"\u00E7", "&ntilde;":"\u00F1",
        "&Aacute;":"\u00C1", "&Atilde;":"\u00C3", "&Acirc;":"\u00C2",
        "&Eacute;":"\u00C9", "&Ecirc;":"\u00CA",
        "&Iacute;":"\u00CD",
        "&Oacute;":"\u00D3", "&Otilde;":"\u00D5", "&Ocirc;":"\u00D4",
        "&Uacute;":"\u00DA", "&Ccedil;":"\u00C7",
        "&quot;":"\"", "&apos;":"'", "&lt;":"<", "&gt;":">", "&nbsp;":" "
    };
    for (var k in ent) {
        while (s.indexOf(k) >= 0) s = s.replace(k, ent[k]);
    }

    // &amp; por ultimo, senao "&amp;ccedil;" viraria "&ccedil;" tarde demais
    while (s.indexOf("&amp;") >= 0) s = s.replace("&amp;", "&");

    return s;
}

// Normaliza como o Sankhya grava: CAIXA ALTA, SEM ACENTO e SEM CARACTERE
// especial.
//
// Necessario porque as fontes divergem: o XML da NF-e vem sem acento
// ("Jardim Santo Antonio"), o ViaCEP vem com ("Jardim Santo Antonio"
// acentuado), e o marketplace as vezes manda entidade HTML
// ("Gon&ccedil;alves"). Sem normalizar, a TSIBAI e a TGFPAR acumulariam
// as varias grafias do mesmo nome -- e como nao ha DELETE disponivel,
// a duplicata fica para sempre.
function normaliza(txt) {
    if (txt == null) return null;

    var s = decodificaHtml(txt);
    s = String(s).replace(/^\s+|\s+$/g, "");
    if (s === "") return null;

    // ---- tira acento, caractere a caractere.
    // Tabela em vez de regex Unicode: o Rhino do Sankhya e antigo e o
    // suporte a \u em regex varia entre versoes.
    var com = "\u00C0\u00C1\u00C2\u00C3\u00C4\u00C5"      // A
            + "\u00C8\u00C9\u00CA\u00CB"                    // E
            + "\u00CC\u00CD\u00CE\u00CF"                    // I
            + "\u00D2\u00D3\u00D4\u00D5\u00D6"             // O
            + "\u00D9\u00DA\u00DB\u00DC"                    // U
            + "\u00C7\u00D1"                                  // C cedilha, N til
            + "\u00E0\u00E1\u00E2\u00E3\u00E4\u00E5"      // a
            + "\u00E8\u00E9\u00EA\u00EB"                    // e
            + "\u00EC\u00ED\u00EE\u00EF"                    // i
            + "\u00F2\u00F3\u00F4\u00F5\u00F6"             // o
            + "\u00F9\u00FA\u00FB\u00FC"                    // u
            + "\u00E7\u00F1";                                 // c cedilha, n til
    var sem = "AAAAAA" + "EEEE" + "IIII" + "OOOOO" + "UUUU" + "CN"
            + "AAAAAA" + "EEEE" + "IIII" + "OOOOO" + "UUUU" + "CN";

    var out = "";
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i);
        var p = com.indexOf(ch);
        out += (p >= 0) ? sem.charAt(p) : ch;
    }
    out = out.toUpperCase();

    // ---- tira caractere especial.
    // Mantem letra, numero, espaco e a pontuacao que aparece em endereco
    // e nome de empresa: ponto, hifen, barra, virgula, parenteses e &.
    // O resto vira espaco -- nao some, para nao colar duas palavras.
    var limpo = "";
    for (var j = 0; j < out.length; j++) {
        var c = out.charAt(j);
        var ok = (c >= "A" && c <= "Z")
              || (c >= "0" && c <= "9")
              || c === " " || c === "." || c === "-" || c === "/"
              || c === "," || c === "(" || c === ")" || c === "&";
        limpo += ok ? c : " ";
    }

    // ---- colapsa espacos repetidos
    while (limpo.indexOf("  ") >= 0) {
        limpo = limpo.replace("  ", " ");
    }
    limpo = limpo.replace(/^\s+|\s+$/g, "");

    return (limpo === "") ? null : limpo;
}

// Confirma no banco que o parceiro existe e satisfaz o que o motor exige:
// "parceiro CLIENTE ATIVO". So depois disso vale limpar a divergencia.
function parceiroConfirmado(documento) {
    if (documento == null) return false;
    try {
        var q = getQuery("native");
        q.setParam("d", String(documento));
        q.nativeSelect("SELECT COUNT(*) AS QTD FROM TGFPAR "
            + "WHERE CGC_CPF = {d} AND CLIENTE = 'S' AND ATIVO = 'S'");
        if (q.next()) return Number(q.getString("QTD")) > 0;
    } catch (e) { }
    return false;
}

// Remove a mensagem de divergencia de parceiro do TGFIXN.CONFIG.
//
// Nao existe UPDATE via script nesta instalacao, entao a limpeza mora
// numa FUNCAO no banco -- funcao pode ser chamada de dentro de um SELECT.
// Ver 04-funcao-limpa-divergencia.sql.
//
// A limpeza e por DOCUMENTO, nao por nota: a view agrupa, e um cliente
// pode ter varias notas pendentes carregando a mesma mensagem.
//
// Devolve quantas notas foram limpas, ou -1 em erro. Falhar aqui nao
// afeta o cadastro -- a mensagem e ruido visual, o parceiro e o que
// importa.
function limpaDivergencia(documento) {
    if (!LIMPAR_DIVERG || documento == null) return 0;
    try {
        var q = getQuery("native");
        q.setParam("doc", String(documento));
        q.nativeSelect("SELECT STP_LIMPA_DIVERG_PARC({doc}) AS QTD FROM DUAL");
        if (q.next()) {
            var n = Number(q.getString("QTD"));
            return (n > 0) ? n : 0;
        }
    } catch (e) { }
    return 0;
}

// Esta na lista de exclusao? Compara pela RAIZ (8 primeiros digitos),
// para cobrir qualquer filial.
function naListaDeExclusao(doc) {
    if (doc == null || String(doc).length < 8) return null;
    var raiz = String(doc).substring(0, 8);
    return (NAO_CADASTRAR[raiz] != null) ? NAO_CADASTRAR[raiz] : null;
}

function soDigitos(txt) {
    if (txt == null) return null;
    return String(txt).replace(/[^0-9]/g, "");
}

// novaLinha aceita nome de tabela ou de instancia, e varia por entidade.
// Tenta os candidatos e usa o primeiro que responder.
function criaLinha(candidatos) {
    for (var i = 0; i < candidatos.length; i++) {
        try {
            var l = novaLinha(candidatos[i]);
            if (l != null) return l;
        } catch (e) { }
    }
    throw "novaLinha falhou para: " + candidatos.join("/");
}

// Le a URL do ViaCEP do parametro do sistema. A coluna de chave da
// TSIPAR e CHAVE (nao NOMEPARAMETRO), e o valor fica em TEXTO.
function urlViaCep() {
    try {
        var q = getQuery("native");
        q.setParam("ch", "URLWSVIACEP");
        q.nativeSelect("SELECT TEXTO FROM TSIPAR WHERE CHAVE = {ch}");
        if (q.next()) {
            var v = q.getString("TEXTO");
            if (v != null && String(v) !== "") return String(v);
        }
    } catch (e) { }
    return URL_VIACEP;
}

// Le o corpo MESMO em erro (getErrorStream): sem isso a mensagem do
// servico se perde e o diagnostico fica cego.
function baixaHttp(endereco) {
    var url = new java.net.URL(endereco);
    var conn = url.openConnection();
    conn.setConnectTimeout(8000);
    conn.setReadTimeout(8000);
    var codigo = conn.getResponseCode();
    var stream = (codigo >= 400) ? conn.getErrorStream() : conn.getInputStream();
    if (stream == null) throw "HTTP " + codigo + " sem corpo";
    var sc = new java.util.Scanner(stream, "UTF-8").useDelimiter("\\A");
    var txt = sc.hasNext() ? sc.next() : "";
    sc.close();
    if (codigo >= 400) throw "HTTP " + codigo + ": " + String(txt);
    return String(txt);
}

function proximoCodigo(tabela, coluna) {
    var q = getQuery("native");
    q.nativeSelect("SELECT NVL(MAX(" + coluna + "), 0) + 1 AS PROX FROM " + tabela);
    q.next();
    return Number(q.getString("PROX"));
}

// -------------------------------------------------------------- BUSCAS
// Parceiro pelo documento (blindado contra NULL: string vazia = NULL no Oracle)
function achaParceiro(doc) {
    if (doc == null || String(doc) === "") return null;
    var q = getQuery("native");
    q.setParam("d", String(doc));
    q.nativeSelect("SELECT CODPARC, NOMEPARC FROM TGFPAR "
        + "WHERE CGC_CPF IS NOT NULL "
        + "AND REGEXP_REPLACE(CGC_CPF, '[^0-9]', '') = {d}");
    if (q.next()) {
        return { cod: Number(q.getString("CODPARC")),
                 nome: String(q.getString("NOMEPARC")) };
    }
    return null;
}

// Cidade pelo codigo IBGE do XML. NAO criamos cidade: a base do Sankhya
// ja vem com os municipios, e criar cidade errada e pior que falhar.
function achaCidade(codIbge) {
    if (codIbge == null || String(codIbge) === "") return null;
    var q = getQuery("native");
    q.setParam("m", String(codIbge));
    q.nativeSelect("SELECT CODCID, NOMECID, CODREG FROM TSICID WHERE CODMUNFIS = {m}");
    if (q.next()) {
        return { cod: Number(q.getString("CODCID")),
                 nome: String(q.getString("NOMECID")),
                 reg: Number(q.getString("CODREG")) };
    }
    return null;
}

// ---- NIVEL 1: cache local. Traz CODCID, CODBAI e CODEND JA VINCULADOS
// entre si -- e a mesma fonte que a tela de Parceiros usa. Risco zero.
function achaPorCep(cep) {
    var c = soDigitos(cep);
    if (c == null || c.length !== 8) return null;
    var q = getQuery("native");
    q.setParam("c", c);
    q.nativeSelect("SELECT CODCID, CODBAI, CODEND FROM TSICEP WHERE CEP = {c}");
    if (q.next()) {
        return { cid: Number(q.getString("CODCID")),
                 bai: Number(q.getString("CODBAI")),
                 end: Number(q.getString("CODEND")),
                 origem: "TSICEP" };
    }
    return null;
}

// Extracao simples de campo JSON de primeiro nivel.
function valorJson(json, campo) {
    var marca = '"' + campo + '"';
    var i = json.indexOf(marca);
    if (i < 0) return null;
    i = json.indexOf(':', i + marca.length);
    if (i < 0) return null;
    var abre = json.indexOf('"', i);
    if (abre < 0) return null;
    var fecha = json.indexOf('"', abre + 1);
    if (fecha < 0) return null;
    return json.substring(abre + 1, fecha);
}

// BAIRRO -- reaproveita por nome, cria so se nao existir.
//
// O Sankhya VALIDA bairro duplicado: tentar criar um nome que ja existe
// devolve "CORE_E00959: Ja existe um bairro cadastrado com o nome X"
// (descoberto em 10/09/2026 ao tentar criar BARRA DA TIJUCA).
//
// Isso resolve uma duvida que tinhamos: como a TSIBAI nao tem coluna de
// cidade, temiamos que buscar por nome vinculasse o bairro do municipio
// errado. Mas se o proprio produto impede duplicata por nome, o bairro E
// um catalogo global -- compartilhado entre cidades por design. Buscar
// por nome e o comportamento esperado, nao um risco.
//
// O CODBAI 3934 estar vinculado a Sao Paulo na TSICEP era coincidencia de
// uso, nao vinculo estrutural.
//
// "CENTRO" usa o CODBAI generico 866 (decisao do Paulo, 10/09) -- na
// pratica a busca por nome acharia o mesmo, mas a constante documenta a
// intencao e evita depender da grafia cadastrada.
function resolveBairro(nomeBairro, codReg) {
    var nome = normaliza(nomeBairro);
    if (nome == null) return null;
    if (nome === "CENTRO") return CODBAI_CENTRO;

    // 1) ja existe?
    try {
        var q = getQuery("native");
        q.setParam("n", corta(nome, 60));
        q.nativeSelect("SELECT MIN(CODBAI) AS COD FROM TSIBAI "
            + "WHERE UPPER(NOMEBAI) = {n}");
        if (q.next()) {
            var achado = q.getString("COD");
            if (achado != null && String(achado) !== "") {
                return Number(achado);
            }
        }
    } catch (eBusca) { }

    // 2) nao existe: cria
    try {
        var cod = proximoCodigo("TSIBAI", "CODBAI");
        var l = criaLinha(["Bairro", "TSIBAI"]);
        l.setCampo("CODBAI",  cod);
        l.setCampo("NOMEBAI", corta(nome, 60));
        l.setCampo("CODREG",  (codReg == null) ? 0 : codReg);   // NOT NULL
        l.setCampo("DTALTER", new Date());                      // NOT NULL
        l.save();
        return cod;
    } catch (e) {
        return null;   // sem bairro e melhor que abortar o cadastro
    }
}

// LOGRADOURO -- mesma logica do bairro: reaproveita por nome, cria so se
// nao existir. O Sankhya valida duplicata de bairro (CORE_E00959) e e
// provavel que valide a de endereco tambem.
//
// O gabarito da integracao guardava o logradouro INTEIRO em NOMEEND,
// deixando TIPO vazio (parceiro 55500). Seguimos esse padrao.
function criaEndereco(logradouro) {
    var nome = normaliza(logradouro);
    if (nome == null) return null;

    // 1) ja existe?
    try {
        var q = getQuery("native");
        q.setParam("n", corta(nome, 60));
        q.nativeSelect("SELECT MIN(CODEND) AS COD FROM TSIEND "
            + "WHERE UPPER(NOMEEND) = {n}");
        if (q.next()) {
            var achado = q.getString("COD");
            if (achado != null && String(achado) !== "") {
                return Number(achado);
            }
        }
    } catch (eBusca) { }

    // 2) nao existe: cria
    try {
        var cod = proximoCodigo("TSIEND", "CODEND");
        var l = criaLinha(["Endereco", "TSIEND"]);
        l.setCampo("CODEND",  cod);
        l.setCampo("NOMEEND", corta(nome, 60));
        l.setCampo("DTALTER", new Date());                      // NOT NULL
        l.save();
        return cod;
    } catch (e) {
        return null;
    }
}

// Alimenta o cache, como a tela de Parceiros faz. Assim o proximo cliente
// da mesma regiao cai no nivel 1 e nem chama o ViaCEP.
function gravaCacheCep(cep, loc) {
    if (loc.end == null || loc.bai == null) return;
    try {
        var l = criaLinha(["TSICEP"]);
        l.setCampo("CEP",    cep);
        l.setCampo("CODCID", loc.cid);
        l.setCampo("CODBAI", loc.bai);
        l.setCampo("CODEND", loc.end);
        l.save();
    } catch (e) {
        // cache e otimizacao: falhar aqui nao afeta o cadastro
    }
}

// ---- NIVEL 2: ViaCEP. Devolve NOMES, entao criamos os cadastros.
// Em simulacao nao cria nada -- so informa que resolveria.
function achaPorViaCep(cep, codCidade, codReg, simular) {
    var c = soDigitos(cep);
    if (c == null || c.length !== 8) return null;

    var json;
    try {
        var base = urlViaCep();
        if (base.charAt(base.length - 1) !== "/") base = base + "/";
        json = baixaHttp(base + c + "/json/");
    } catch (e) {
        return null;   // servico indisponivel nao impede o cadastro
    }

    if (json == null || json.indexOf('"erro"') >= 0) return null;

    var logradouro = valorJson(json, "logradouro");
    var bairro     = valorJson(json, "bairro");

    // CEP geral de municipio volta com logradouro vazio. Nao ha endereco
    // a criar -- nem a tela do Sankhya resolve esses.
    if (logradouro == null || logradouro.replace(/^\s+|\s+$/g, "") === "") {
        return null;
    }

    if (simular) {
        return { cid: codCidade, bai: null, end: null,
                 origem: "VIACEP (criaria: " + corta(logradouro, 30)
                       + " / " + corta(bairro, 20) + ")" };
    }

    var loc = { cid: codCidade,
                bai: resolveBairro(bairro, codReg),
                end: criaEndereco(logradouro),
                origem: "VIACEP" };
    gravaCacheCep(c, loc);
    return loc;
}

// Resolve o endereco percorrendo os niveis em ordem.
function resolveEndereco(cep, codCidade, codReg, simular) {
    var loc = USAR_TSICEP ? achaPorCep(cep) : null;
    if (loc != null) return loc;
    if (USAR_VIACEP) {
        loc = achaPorViaCep(cep, codCidade, codReg, simular);
        if (loc != null) return loc;
    }
    return null;   // nivel 3: so a cidade
}

// Grava o parceiro. Com retentativa: MAX+1 pode colidir se alguem
// cadastrar pela tela no mesmo instante. Nao corrompe nada -- so falha.
function criaParceiro(d, codEnd, codBai, codCid) {
    var ultimoErro = null;

    for (var t = 0; t < TENTATIVAS_PK; t++) {
        var cod = proximoCodigo("TGFPAR", "CODPARC");
        try {
            var l = criaLinha(["Parceiro", "TGFPAR"]);

            // --- os 5 obrigatorios sem DEFAULT no banco
            l.setCampo("CODPARC",   cod);
            l.setCampo("NOMEPARC",  corta(normaliza(d.nome), 80));
            l.setCampo("TIPPESSOA", d.tipPessoa);
            l.setCampo("DTCAD",     new Date());
            l.setCampo("DTALTER",   new Date());

            // --- documento
            l.setCampo("CGC_CPF", d.doc);

            // Rastreabilidade: o gabarito de producao grava o usuario que
            // importou (33 e 105 nos parceiros 61662/61670). Aqui fica o
            // usuario da sessao, para saber que veio deste botao.
            try { l.setCampo("CODUSU", getUsuarioLogado()); } catch (eU) { }

            // --- CLIENTE e o UNICO campo em que o default do dicionario do
            // Sankhya ('N') sobrescreve o default do banco ('S'). Comprovado
            // em 09/09: os parceiros 58773/58774/58775 sairam com CLIENTE='N',
            // enquanto os 24 outros campos com default sairam corretos e
            // identicos ao gabarito da Tem Api (55500 / 56811).
            // Parceiro com CLIENTE='N' nao aparece na busca de clientes.
            l.setCampo("CLIENTE", "S");

            // --- localizacao (default 0 se nao houver)
            if (codEnd != null) l.setCampo("CODEND", codEnd);
            if (codBai != null) l.setCampo("CODBAI", codBai);
            if (codCid != null) l.setCampo("CODCID", codCid);

            // --- opcionais: cada um isolado, porque o tipo de coluna
            // (CEP como texto ou numero, por ex.) nao esta confirmado.
            // Falha em um nao impede o cadastro.
            var opc = "";
            if (d.nro    != null) { try { l.setCampo("NUMEND", corta(d.nro, 10)); }
                                    catch (e1) { opc += "NUMEND "; } }
            if (d.cpl    != null) { try { l.setCampo("COMPLEMENTO", corta(normaliza(d.cpl), 60)); }
                                    catch (e2) { opc += "COMPLEMENTO "; } }
            if (d.cep    != null) { try { l.setCampo("CEP", soDigitos(d.cep)); }
                                    catch (e3) { opc += "CEP "; } }
            if (d.nome   != null) { try { l.setCampo("RAZAOSOCIAL",
                                        corta(normaliza(d.nome), 80)); }
                                    catch (e5) { opc += "RAZAOSOCIAL "; } }

            l.save();
            return { cod: cod, opcionaisFalhos: opc };

        } catch (e) {
            ultimoErro = e;
            // se foi colisao de PK, o proximo laco pega um MAX novo
        }
    }
    throw "falhou em " + TENTATIVAS_PK + " tentativas: " + ultimoErro;
}

// View e somente leitura: nao ha onde gravar resultado.
// Mantida como no-op para o corpo do script ficar identico ao da versao
// de tabela -- se um dia rodar sobre tabela, basta reimplementar aqui.
function gravaResultado(linhaObj, codParc, obs) {
    return true;
}

// ============================================================ ETAPA 1
// Linhas selecionadas na grade
var alvos = [];
try {
    if (linhas != null && linhas.length > 0) {
        for (var L = 0; L < linhas.length && L < MAX_LINHAS; L++) {
            alvos.push({ nu: Number(linhas[L].getCampo('NUARQUIVO')),
                         linha: linhas[L] });
        }
    }
} catch (eSel) { }

if (alvos.length === 0) {
    mensagem = "Selecione na grade as linhas cujos parceiros deseja cadastrar,"
             + " depois clique novamente.";
} else {

// ============================================================ ETAPA 2
var jaTinha = 0, criados = 0, comEnd = 0, semCidade = 0, semEndereco = 0;
var ignorados = 0, limpasTotal = 0;
var falhas = 0, logFalhou = 0;
var listaOk = "", listaSemEnd = "", listaIgnor = "", listaErro = "", avisos = "";

for (var a = 0; a < alvos.length; a++) {
    var nuArq    = alvos[a].nu;
    var linhaObj = alvos[a].linha;

    try {
        // As colunas da TGFIXN vem NULAS no upload manual pelo Portal
        // (CHAVEACESSO, CNPJPARC, CNPJDEST, CODEMP, CODTIPOPER). So o XML
        // e o NOMEARQUIVO sao gravados. Por isso tudo sai do XML.
        var q = getQuery("native");
        q.setParam("nu", nuArq);
        q.nativeSelect("SELECT XML FROM TGFIXN WHERE NUARQUIVO = {nu}");
        if (!q.next()) throw "nota nao encontrada na TGFIXN";

        var xmlBruto = q.getString("XML");
        if (xmlBruto == null || String(xmlBruto).length < 500) {
            throw "XML ausente ou ilegivel nesta nota";
        }
        var xml = String(xmlBruto);

        var bDestPrev = bloco(xml, "dest");
        if (bDestPrev === "") {
            throw "XML sem bloco <dest> (documento de outro tipo?)";
        }
        var docPrev = extrai(bDestPrev, "CNPJ");
        if (docPrev == null) docPrev = extrai(bDestPrev, "CPF");

        // --- lista de exclusao, por raiz de CNPJ
        var motivoExcl = naListaDeExclusao(soDigitos(docPrev));
        if (motivoExcl != null) {
            ignorados++;
            if (listaIgnor.length < 300) {
                listaIgnor += "\n   [" + nuArq + "] " + motivoExcl;
            }
            continue;
        }

        // --- ja existe? nao mexe
        var existente = achaParceiro(soDigitos(docPrev));
        if (existente != null) {
            jaTinha++;
            if (!MODO_SIMULACAO) {
                gravaResultado(linhaObj, existente.cod,
                    "Parceiro ja existia: " + existente.cod
                    + " - " + existente.nome);
            }
            continue;
        }

        // --- extrai o cadastro do bloco <dest> do XML
        var bDest = bDestPrev;
        var bEnd  = bloco(bDest, "enderDest");

        var cnpjD = extrai(bDest, "CNPJ");
        var cpfD  = extrai(bDest, "CPF");

        var d = {
            doc:       soDigitos((cnpjD != null) ? cnpjD : cpfD),
            tipPessoa: (cnpjD != null) ? "J" : "F",
            nome:      extrai(bDest, "xNome"),
            lgr:       extrai(bEnd, "xLgr"),
            nro:       extrai(bEnd, "nro"),
            cpl:       extrai(bEnd, "xCpl"),
            bairro:    extrai(bEnd, "xBairro"),
            cMun:      extrai(bEnd, "cMun"),
            xMun:      extrai(bEnd, "xMun"),
            uf:        extrai(bEnd, "UF"),
            cep:       extrai(bEnd, "CEP")
        };

        if (d.doc == null || d.doc === "") throw "XML sem CNPJ/CPF no <dest>";
        if (d.nome == null)                throw "XML sem xNome no <dest>";

        // --- cidade: localiza pelo IBGE, nunca cria
        var cid = achaCidade(d.cMun);
        if (cid == null) {
            semCidade++;
            throw "cidade IBGE " + d.cMun + " (" + d.xMun + "/" + d.uf
                + ") nao existe na TSICID";
        }

        // ---------------------------------------------- ENDERECO
        var loc = resolveEndereco(d.cep, cid.cod, cid.reg, MODO_SIMULACAO);

        if (MODO_SIMULACAO) {
            criados++;   // aqui significa "seria criado"
            if (loc == null) {
                semEndereco++;
                if (listaSemEnd.length < 400) {
                    listaSemEnd += "\n   [" + nuArq + "] " + corta(d.nome, 24)
                        + "  -  CEP " + d.cep + " (" + corta(cid.nome, 14) + ")";
                }
            } else {
                comEnd++;
                if (listaOk.length < 400) {
                    listaOk += "\n   [" + nuArq + "] " + corta(d.nome, 24)
                        + "  -  " + loc.origem
                        + (loc.end == null ? "" : " end " + loc.end + " / bai " + loc.bai);
                }
            }
            continue;
        }

        // ---------------------------------------------- GRAVACAO
        // Endereco so quando a TSICEP resolve. Sem CEP conhecido, o
        // parceiro nasce com a cidade certa (do IBGE) e sem logradouro.
        var codEnd = (loc == null) ? null : loc.end;
        var codBai = (loc == null) ? null : loc.bai;

        var res = criaParceiro(d, codEnd, codBai, cid.cod);
        criados++;

        var obs;
        if (loc == null) {
            semEndereco++;
            obs = "PARCEIRO CRIADO SEM ENDERECO - completar manualmente."
                + " CEP " + d.cep + " nao esta na TSICEP e o ViaCEP nao"
                + " devolveu logradouro (CEP geral de municipio?)."
                + " Do XML: " + corta(d.lgr, 60)
                + ", nro " + d.nro
                + ", bairro " + corta(d.bairro, 30)
                + ", " + corta(d.xMun, 20) + "/" + d.uf;
            if (listaSemEnd.length < 400) {
                listaSemEnd += "\n   [" + nuArq + "] CODPARC " + res.cod
                    + "  " + corta(d.nome, 22) + "  -  CEP " + d.cep;
            }
        } else {
            comEnd++;
            obs = "Parceiro criado com endereco completo (" + loc.origem + ")."
                + " CODEND " + loc.end + " / CODBAI " + loc.bai;
            if (listaOk.length < 400) {
                listaOk += "\n   [" + nuArq + "] CODPARC " + res.cod
                    + "  " + corta(d.nome, 22);
            }
        }

        // Limpa a divergencia SO depois de confirmar que o parceiro esta
        // gravado E serve ao motor (CLIENTE='S' e ATIVO='S').
        // Nao basta o save() ter passado: se ele falhasse em silencio,
        // estariamos apagando a mensagem de um parceiro inexistente.
        if (parceiroConfirmado(d.doc)) {
            limpasTotal += limpaDivergencia(d.doc);
        }

        if (res.opcionaisFalhos !== "") {
            obs += " | Campos nao aceitos: " + res.opcionaisFalhos;
            if (avisos.length < 200) {
                avisos += "\n   [" + nuArq + "] " + res.opcionaisFalhos;
            }
        }

        if (!gravaResultado(linhaObj, res.cod, obs)) logFalhou++;

    } catch (e) {
        falhas++;
        if (!MODO_SIMULACAO) {
            gravaResultado(linhaObj, null, "ERRO ao cadastrar parceiro: " + e);
        }
        if (listaErro.length < 400) {
            listaErro += "\n   [" + nuArq + "] " + e;
        }
    }
}

// ============================================================ RESUMO
// Mensagem estruturada por categoria + log na AD_TESTENOTA.
// 'mensagem', nunca 'throw': throw daria rollback nos cadastros feitos.

var cab = MODO_SIMULACAO
        ? "SIMULACAO - nada foi gravado"
        : "CADASTRO DE PARCEIROS";

var texto = cab
    + "\n" + alvos.length + " linha(s) selecionada(s)"
    + "\n"
    + "\n  " + (MODO_SIMULACAO ? "SERIAM CRIADOS" : "CRIADOS") + ": " + criados
    + "   (com endereco: " + comEnd + "  |  sem endereco: " + semEndereco + ")"
    + "\n  JA EXISTIAM: " + jaTinha
    + "\n  IGNORADOS POR REGRA: " + ignorados
    + "\n  ERROS: " + falhas
    + (limpasTotal > 0
       ? "\n  DIVERGENCIAS LIMPAS: " + limpasTotal + " nota(s)"
       : "");

if (listaOk !== "") {
    texto += "\n\nCOM ENDERECO COMPLETO:" + listaOk;
}
if (listaSemEnd !== "") {
    texto += "\n\nSEM ENDERECO - completar manualmente na tela de Parceiros:"
           + listaSemEnd;
}
if (listaIgnor !== "") {
    texto += "\n\nIGNORADOS (cadastro manual por decisao):" + listaIgnor;
}
if (listaErro !== "") {
    texto += "\n\nERROS:" + listaErro;
}
if (avisos !== "") {
    texto += "\n\nCAMPOS NAO ACEITOS:" + avisos;
}
if (logFalhou > 0) {
    texto += "\n\nATENCAO: " + logFalhou + " linha(s) da fila nao receberam o"
           + " resultado (a coluna Situacao do parceiro ficou vazia)."
           + " O parceiro FOI criado -- confira na TGFPAR.";
}

// ---- log de uma linha na AD_TESTENOTA
if (!MODO_SIMULACAO) {
    try {
        var resumoCurto = "sel=" + alvos.length
                        + " criados=" + criados
                        + " (cEnd=" + comEnd + " sEnd=" + semEndereco + ")"
                        + " jaTinham=" + jaTinha
                        + " erros=" + falhas;
        var log = novaLinha('AD_TESTENOTA');
        log.setCampo('TIPONOTA', corta('CADASTRO PARCEIRO', 30));
        log.setCampo('STATUS',   corta(resumoCurto, 100));
        log.setCampo('NOMEPARC', corta(
            (listaErro !== "" ? "ERROS:" + listaErro : "sem erros"), 60));
        log.setCampo('DTIMPORT', new Date());
        log.save();
    } catch (eLog) { }
}

mensagem = texto;

}  // fim do else
