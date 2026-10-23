"""269 / M5: builders for the staging Cerebro agent tools declarar_servicio, cambiar_servicio, agregar_servicio.

Pure functions (no network). The intent is the agent's; the database validates money and executes
(odd/tasks/service-resolution.md, REDESIGN 2026-10-22). Nothing here reads customer words.
"""
import copy
import re
import uuid

SERVICIOS = ("recarga, combo, visa, saldo, cuban_card (tarjeta en pesos CUP), clasica, tropical, zelle, "
             "efectivo_usd (dolares fisicos en Cuba), mexico")

MODOS = {
    "declarar": ("declarar_servicio", "agent:declarar_servicio"),
    "cambiar": ("cambiar_servicio", "agent:cambiar_servicio"),
    "agregar": ("agregar_servicio", "agent:agregar_servicio"),
}

# Key normalisation only (the old prompt used 'cup' and 'efectivo'); it infers nothing from the customer's words.
_CLAVE = ("CASE lower(btrim($2::text)) WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd' "
          "WHEN 'saldo movil' THEN 'saldo' WHEN 'méxico' THEN 'mexico' ELSE lower(btrim($2::text)) END")

_DESC = {
    "declarar": (
        "Anota el servicio que el cliente DICE que quiere, en cuanto lo diga y ANTES de que deposite: 'recarga', 'combo', "
        "'visa', 'saldo', 'cuban_card' (tarjeta en pesos), 'clasica', 'tropical', 'zelle', 'efectivo_usd' o 'mexico'. "
        "Solo guarda la intencion (vale la ultima que declares): no mueve dinero ni cambia operaciones; para cambiar o "
        "sumar un servicio cuando ya hay envio abierto usa cambiar_servicio / agregar_servicio. NO la llames si solo "
        "pregunta un precio o compara, ni con una clave que el cliente no haya elegido. Devuelve ok y mensaje."),
    "cambiar": (
        "El cliente DECIDIO cambiar el servicio de ESTE envio por otro: 'recarga', 'combo', 'visa', 'saldo', "
        "'cuban_card' (tarjeta en pesos), 'clasica', 'tropical', 'zelle', 'efectivo_usd' o 'mexico'. Llamala ANTES de "
        "responder. NO la llames si solo pregunta un precio o compara, si habla de otra persona u otro envio, ni para "
        "SUMAR un servicio (eso es agregar_servicio). La base valida el deposito contra el minimo y ejecuta. Devuelve "
        "mensaje (en espanol, para decirselo al cliente), aplicado, permitido, motivo, minimo_gyd y faltante_gyd."),
    "agregar": (
        "El cliente quiere ADEMAS otro servicio sin dejar el que ya tiene: 'recarga', 'combo', 'visa', 'saldo', "
        "'cuban_card' (tarjeta en pesos), 'clasica', 'tropical', 'zelle', 'efectivo_usd' o 'mexico'. Llamala ANTES de "
        "responder. Si un mismo deposito cubre los dos minimos la base los reparte; si no, abre una operacion aparte que "
        "espera su propio deposito. NO la llames para reemplazar un servicio (eso es cambiar_servicio). Devuelve mensaje "
        "(en espanol, para decirselo al cliente), aplicado, permitido, motivo, minimo_gyd y faltante_gyd."),
}

_FROMAI_SERVICIO = {
    "declarar": ("la clave del servicio que el cliente dijo que quiere: " + SERVICIOS),
    "cambiar": ("la clave del servicio al que cambia el cliente: " + SERVICIOS),
    "agregar": ("la clave del servicio que el cliente quiere ademas del que ya tiene: " + SERVICIOS),
}


def descripcion(modo):
    return _DESC[modo]


def reemplazo(modo):
    return ("={{ [$('Decisor').item.json.conversation_id, $fromAI('servicio', '" + _FROMAI_SERVICIO[modo]
            + "', 'string'), $execution.id] }}")


def consulta(modo):
    _, actor = MODOS[modo]
    if modo == "declarar":
        return (
            "-- 269: the agent declares the service the customer stated (latest declaration wins). Facts only.\n"
            "SELECT (r ->> 'ok')::boolean AS ok, r ->> 'servicio' AS servicio, r ->> 'motivo' AS motivo,\n"
            "       CASE WHEN (r ->> 'ok')::boolean THEN 'Anotado: el cliente va por ' || (r ->> 'servicio')\n"
            "            ELSE 'No se pudo anotar el servicio: ' || coalesce(r ->> 'motivo', 'error') END AS mensaje\n"
            "  FROM (SELECT cerebro_declarar_servicio($1::uuid, " + _CLAVE + ", '" + actor + "') AS r,\n"
            "               $3::text AS ejecucion) x;")
    return (
        "-- 269: the agent decided the intent; the database checks the money and executes (cerebro_aplicar_servicio).\n"
        "SELECT r ->> 'mensaje' AS mensaje, (r ->> 'aplicado')::boolean AS aplicado, (r ->> 'permitido')::boolean AS permitido,\n"
        "       r ->> 'motivo' AS motivo, r ->> 'servicio' AS servicio, r ->> 'en_curso' AS en_curso,\n"
        "       r ->> 'minimo_gyd' AS minimo_gyd, r ->> 'faltante_gyd' AS faltante_gyd\n"
        "  FROM (SELECT cerebro_aplicar_servicio($1::uuid, " + _CLAVE + ", '" + modo + "', '" + actor + "', $3::text) AS r) x;")


def consulta_numeros():
    return ("-- RECARGAS: guarda (agregar) o quita (quitar, 282) los numeros de Cuba de la recarga. p_abrir: the agent understood a recharge, it opens\n"
            "-- it even before any number (quitar never opens). The actor carries the n8n execution id.\n"
            "SELECT crm_registrar_numeros_recarga($1::uuid, $2, true, 'agent:registrar_numeros_recarga n8n:' || $3, "
            "COALESCE(NULLIF($4,''),'agregar')) AS resultado;")


def reemplazo_numeros():
    return ("={{ [$('Decisor').item.json.conversation_id, "
            "$fromAI('numeros', 'los numeros de Cuba que dijo el cliente, tal cual, separados por espacio', 'string'), $execution.id, "
            "$fromAI('accion', 'agregar (por defecto) para sumar numeros a la recarga, quitar para sacar los numeros que el cliente ya no quiere', 'string', '')] }}")


DESC_NUMEROS = ("Abre la RECARGA en curso (tambien si el cliente la pidio por AUDIO) y guarda los numeros de Cuba a recargar (uno por recarga) que dio el cliente; "
                "numeros puede ir vacio si aun no los dio. Con accion=quitar saca de la recarga los numeros que el cliente ya no quiere (nunca abre una recarga). "
                "Devuelve cuantos numeros faltan o quedaron.")


def consulta_mexico():
    return ("-- M5: a Mexico recipient (migration 271). The function has no p_actor: the actor travels as the p_exec prefix.\n"
            "-- M5b: a Mexico recipient (migration 271). tipo mexico_cuenta: clabe (18 digits), banco, nombre = holder.\n"
            "-- tipo mexico_retiro: banco Coppel|BBVA, nombre = receiver, telefono. Partial data is merged by the database.\n"
            "SELECT r ->> 'mensaje' AS mensaje, (r ->> 'ok')::boolean AS ok, r ->> 'beneficiary_id' AS beneficiary_id\n"
            "  FROM (SELECT cerebro_guardar_beneficiario_mexico($1::uuid, $2::text, $3::text, $4::text, $5::text, $6::text, "
            "'agent:registrar_destinatario_mexico n8n:' || $7::text) AS r) x;")


def reemplazo_mexico():
    return ("={{ [$('Decisor').item.json.conversation_id, "
            "$fromAI('tipo', 'mexico_cuenta (cuenta bancaria con CLABE) o mexico_retiro (retiro sin tarjeta en Coppel o BBVA)', 'string'), "
            "$fromAI('clabe', 'CLABE de 18 digitos, solo numeros (vacio si es retiro o aun no la dio)', 'string', ''), "
            "$fromAI('banco', 'banco de la cuenta (Mercado Pago, Banco Azteca...) o, en retiro, Coppel o BBVA', 'string', ''), "
            "$fromAI('nombre', 'titular de la cuenta, o en retiro el nombre completo de quien recibe', 'string', ''), "
            "$fromAI('telefono', 'telefono de quien recibe (retiro sin tarjeta); vacio en cuenta bancaria', 'string', ''), "
            "$execution.id] }}")


DESC_MEXICO = (
    "Guarda o completa el destinatario de un envio a MEXICO (pesos mexicanos). tipo 'mexico_cuenta': CLABE de 18 digitos, banco "
    "(Mercado Pago, Banco Azteca...) y titular en nombre. tipo 'mexico_retiro': retiro sin tarjeta, banco Coppel o BBVA, nombre "
    "de quien recibe y su telefono. Llamala cuando tengas la CLABE completa (cuenta) o banco, nombre y telefono (retiro); la base rechaza una CLABE que no tenga 18 digitos. Una llamada por cuenta o retiro. "
    "Devuelve mensaje con lo guardado y lo que FALTA: dile al cliente solo eso. NO inventes ni completes una CLABE.")


def _nodo(wf, nombre):
    return next((n for n in wf["nodes"] if n["name"] == nombre), None)


def _poner(n, modo):
    p = n["parameters"]
    p["query"] = consulta(modo)
    p.setdefault("options", {})["queryReplacement"] = reemplazo(modo)
    p["toolDescription"] = descripcion(modo)
    p["descriptionType"] = "manual"
    n["notes"] = ("269: " + modo + ". La intencion la decide el agente; la base valida dinero/minimos y ejecuta "
                  "(cerebro_aplicar_servicio / cerebro_declarar_servicio). Actor " + MODOS[modo][1] + ".")


def aplicar_herramientas(wf):
    """Edit cambiar_servicio in place, clone it for declarar/agregar, wire them to the agent, fix the numbers tool."""
    base = _nodo(wf, "cambiar_servicio")
    if base is None:
        raise ValueError("cambiar_servicio not found")
    _poner(base, "cambiar")
    for modo in ("declarar", "agregar"):
        nombre = MODOS[modo][0]
        n = _nodo(wf, nombre)
        if n is None:
            n = copy.deepcopy(base)
            n["id"] = str(uuid.uuid4())
            n["name"] = nombre
            n["position"] = [base["position"][0] + (160 if modo == "declarar" else 320), base["position"][1]]
            wf["nodes"].append(n)
        _poner(n, modo)
        wf["connections"][nombre] = {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}
    mx = _nodo(wf, "registrar_destinatario_mexico")
    if mx is None:
        mx = copy.deepcopy(base)
        mx["id"] = str(uuid.uuid4())
        mx["name"] = "registrar_destinatario_mexico"
        mx["position"] = [base["position"][0] + 480, base["position"][1]]
        wf["nodes"].append(mx)
    mx["parameters"]["query"] = consulta_mexico()
    mx["parameters"].setdefault("options", {})["queryReplacement"] = reemplazo_mexico()
    mx["parameters"]["toolDescription"] = DESC_MEXICO
    mx["parameters"]["descriptionType"] = "manual"
    mx["notes"] = ("M5: destinatario Mexico (cuenta con CLABE o retiro Coppel/BBVA) via cerebro_guardar_beneficiario_mexico "
                   "(271). Actor agent:registrar_destinatario_mexico.")
    wf["connections"]["registrar_destinatario_mexico"] = {
        "ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}
    aplicar_zelle(wf)
    aplicar_destino(wf)
    aplicar_repartir(wf)
    num = _nodo(wf, "registrar_numeros_recarga")
    if num is None:
        raise ValueError("registrar_numeros_recarga not found")
    num["parameters"]["query"] = consulta_numeros()
    num["parameters"].setdefault("options", {})["queryReplacement"] = reemplazo_numeros()
    num["parameters"]["toolDescription"] = DESC_NUMEROS
    aplicar_noche4(wf)
    return wf


# ---------------------------------------------------------------------------------------------------------------
# Prompt (Agente Remesas, options.systemMessage). Prompt text follows the existing prompt language (Spanish, no accents).

LINEA_CAMBIAR = ("- cambiar_servicio(servicio): cambia la via de la operacion abierta ('zelle', 'clasica', 'tropical', 'cup' o "
                 "'efectivo'). Ver CAMBIO DE VIA.")

HERRAMIENTAS = (
    "- declarar_servicio(servicio): anota el servicio que el cliente DICE que quiere, en cuanto lo diga y ANTES de que deposite "
    "(recarga, combo, visa, saldo, cuban_card, clasica, tropical, zelle, efectivo_usd o mexico). Solo guarda la intencion. Ver "
    "DECLARAR, CAMBIAR Y AGREGAR SERVICIO.\n"
    "- cambiar_servicio(servicio): el cliente DECIDIO cambiar el servicio de este envio por otro (mismas claves). La base valida "
    "el deposito y ejecuta. Ver DECLARAR, CAMBIAR Y AGREGAR SERVICIO.\n"
    "- agregar_servicio(servicio): el cliente quiere ADEMAS otro servicio sin dejar el que tiene (mismas claves). Ver DECLARAR, "
    "CAMBIAR Y AGREGAR SERVICIO.")

SECCION = """## DECLARAR, CAMBIAR Y AGREGAR SERVICIO (tu decides la intencion; la base valida el dinero y ejecuta)
Tu entiendes lo que el cliente quiere con el contexto de la conversacion. La base solo comprueba hechos (deposito contra minimo, estados, bloqueos) y ejecuta. Claves de servicio: recarga, combo, visa, saldo, cuban_card (tarjeta en pesos), clasica, tropical, zelle, efectivo_usd, mexico.
- DECLARAR: en cuanto el cliente diga que servicio quiere, ANTES de que deposite, llama declarar_servicio(servicio) con una clave concreta ('quiero una recarga', 'mandar a Mexico', 'por Zelle'). Si dice solo 'enviar dinero a Cuba' sin via, no declares: preguntale la via. Si despues elige otra, declara de nuevo (vale la ultima). Si devuelve ok=false, no se lo menciones al cliente y sigue.
- CAMBIAR: el cliente DECIDIO cambiar el servicio de ESTE envio ('mejor zelle', 'ponlo en efectivo', 'no, en CUP', 'mejor una recarga'), antes o despues del comprobante: cambiar_servicio(servicio).
- AGREGAR: el cliente quiere ADEMAS otro servicio sin dejar el que tiene ('y tambien una recarga', 'aparte quiero mandar a Mexico'): agregar_servicio(servicio).
- NO es declarar, cambiar ni agregar: una pregunta de precio ('¿y por zelle cuanto seria?'), comparar servicios, hablar de otra persona u otro envio ('mi hermano usa zelle'), o nombrar el servicio que ya tiene (`riel_operacion` del [CONTEXTO]). Si dudas, pregunta: '¿Quiere que se lo cambie a <servicio>?' o '¿Lo quiere ademas del que ya tiene?'.
- NUNCA adivines el servicio por el comprobante, por el monto depositado ni por un dato suelto (una tarjeta, un celular): el servicio es el que el cliente dijo. Si no lo dijo, preguntalo.
- Llama a la herramienta PRIMERO, ANTES de escribir la respuesta. PROHIBIDO decir que ya cambio o agrego si en este turno no la llamaste. PROHIBIDO usar calcular_usd, calcular_usd_desde_gyd o marcar_destino_usd para hacer un cambio.
Resultado de cambiar_servicio y agregar_servicio (campos mensaje, aplicado, permitido, motivo, minimo_gyd, faltante_gyd): dile al cliente lo que dice `mensaje`, de usted y sin inventar cifras.
- aplicado=true: ya esta hecho. Si hace falta una cifra nueva, cotiza con calcular_usd / calcular_usd_desde_gyd / calcular_envio (nunca de memoria) y pide SOLO los datos del servicio nuevo (Zelle: nombre y cuenta; tarjeta: tarjeta y celular; recarga: numeros; efectivo: lo que falte). Los datos del destinatario anterior ya no sirven.
- aplicado=false y permitido=true (motivo sin_cambio o nueva_operacion): no habia nada que mover; confirma el servicio sin cifras nuevas.
- motivo deposito_bajo_minimo: di el minimo y lo que falta tal como viene en `mensaje`; ofrece mantener el servicio actual o completar la diferencia. No se cambio nada.
- motivo grupo_mixto: ese envio es mixto y se cambia con repartir_envio, solo si el cliente confirma las partes.
- motivo estado_no_permite, bloqueada, depositos_separados o varias_operaciones: 'Un compañero le ayuda con ese cambio enseguida.' y llama derivar_humano. No prometas el cambio. (Excepcion a la regla 10: aqui SI.)
- motivo recarga_sin_promo: no hay promocion de recarga vigente; dilo sin insistir.
- motivo servicio_invalido: si el servicio era mexico, ofrece pasar con un operador; en otro caso pregunta a cual servicio se refiere.
- agregar con operacion aparte: explica que esa operacion necesita su propio deposito, del minimo que dice `mensaje`.
- MEXICO: se declara y se cotiza como cualquier servicio (calcular_usd / calcular_usd_desde_gyd con via=mexico); los datos de quien recibe y el pase a un operador siguen lo que devuelva consultar_servicio('mexico')."""

EJEMPLO_VIEJO = ("C: Mejor zelle (envio abierto en efectivo, deposito verificado, 47,100 GYD) -> [llama cambiar_servicio('zelle')] "
                 "'Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD en efectivo). ¿A nombre de "
                 "quien esta la cuenta Zelle y cual es el correo o celular?'  ## primero la herramienta, luego solo las cifras "
                 "que devolvio")

EJEMPLOS_NUEVOS = (
    "C: Mejor zelle (envio abierto en efectivo, deposito verificado, 47,100 GYD) -> [llama cambiar_servicio('zelle'), luego "
    "calcular_usd_desde_gyd(47100, via=zelle)] 'Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD*. ¿A nombre de "
    "quien esta la cuenta Zelle y cual es el correo o celular?'  ## primero la herramienta, luego solo las cifras que devolvio "
    "una tool\n\n"
    "C: Quiero hacer una recarga (aun no deposita) -> [llama declarar_servicio('recarga')] 'Con gusto. ¿A que numero de Cuba "
    "quiere recargar?'  ## declara en cuanto lo dice, antes de pagar\n\n"
    "C: Y tambien quiero una recarga (ya tiene un envio abierto por Zelle) -> [llama agregar_servicio('recarga')] dices lo que "
    "devuelve `mensaje`  ## ademas, no en lugar de")


LINEA_MEXICO_VIEJA = SECCION[SECCION.index("- MEXICO:"):]

LINEA_HERR_MEXICO = (
    "- registrar_destinatario_mexico(tipo, clabe, banco, nombre, telefono): guarda o completa el destinatario de un envio a "
    "MEXICO. tipo mexico_cuenta (CLABE de 18 digitos + banco + titular en nombre) o mexico_retiro (retiro sin tarjeta en Coppel o "
    "BBVA + nombre de quien recibe + telefono). Vacio en lo que no haya dado. Ver MEXICO en DECLARAR, CAMBIAR Y AGREGAR SERVICIO.")

MEXICO_NUEVO = (
    "- MEXICO: apenas el cliente diga que quiere mandar a Mexico, declarar_servicio('mexico'). Cotiza con calcular_usd / "
    "calcular_usd_desde_gyd con via=mexico (nunca de memoria). Pidele, en un solo mensaje, la cuenta bancaria: CLABE (18 "
    "digitos exactos), banco (Mercado Pago, Banco Azteca...) y titular; o el retiro sin tarjeta: Coppel o BBVA (multiplos de "
    "100), nombre completo de quien recibe y su telefono. En cuanto tengas la CLABE completa (cuenta) o banco, nombre y telefono (retiro), registrar_destinatario_mexico(tipo, clabe, banco, "
    "nombre, telefono) con tipo mexico_cuenta o mexico_retiro (una llamada por cuenta o retiro; varios destinatarios, uno por uno); "
    "NUNCA inventes ni completes una CLABE: si no tiene 18 digitos, pidela de nuevo. Dile al cliente lo que diga `mensaje` y "
    "pide solo lo que falte. Cuando los datos esten completos NO llames derivar_humano ni ofrezcas un operador por ser Mexico: "
    "sigue el flujo normal (deposito y verificacion). Solo deriva por las razones generales de la regla 10.")



MEXICO_V1 = (
    "- MEXICO: apenas el cliente diga que quiere mandar a Mexico, declarar_servicio('mexico'). Cotiza con calcular_usd / "
    "calcular_usd_desde_gyd con via=mexico (nunca de memoria). Pidele, en un solo mensaje, la cuenta bancaria: CLABE (18 "
    "digitos exactos), banco (Mercado Pago, Banco Azteca...) y titular; o el retiro sin tarjeta: Coppel o BBVA (multiplos de "
    "100), nombre completo de quien recibe y su telefono. En cuanto tengas algo, registrar_destinatario_mexico(tipo, clabe, banco, "
    "nombre, telefono) con tipo mexico_cuenta o mexico_retiro (una llamada por cuenta o retiro; varios destinatarios, uno por uno); "
    "NUNCA inventes ni completes una CLABE: si no tiene 18 digitos, pidela de nuevo. Dile al cliente lo que diga `mensaje` y "
    "pide solo lo que falte. Cuando los datos esten completos NO llames derivar_humano ni ofrezcas un operador por ser Mexico: "
    "sigue el flujo normal (deposito y verificacion). Solo deriva por las razones generales de la regla 10.")


def editar_prompt(sm):
    """Idempotent: swap the old CAMBIO DE VIA section and tool line for the declare/change/add contract; Mexico step."""
    if "## DECLARAR, CAMBIAR Y AGREGAR SERVICIO" in sm:
        return _mexico(sm)
    sm = sm.replace(LINEA_CAMBIAR, HERRAMIENTAS)
    i = sm.index("## CAMBIO DE VIA")
    j = sm.index("## ESTILO", i)
    sm = sm[:i] + SECCION + "\n\n" + sm[j:]
    sm = sm.replace("(ver CAMBIO DE VIA)", "(ver DECLARAR, CAMBIAR Y AGREGAR SERVICIO)")
    sm = sm.replace("Tambien cuando cambiar_servicio responde estado_no_permite, bloqueado_por_humano, tipo_no_soportado o "
                    "varios_destinatarios",
                    "Tambien cuando cambiar_servicio o agregar_servicio responden motivo estado_no_permite, bloqueada, "
                    "depositos_separados o varias_operaciones")
    sm = sm.replace("Ver CAMBIO DE VIA.", "Ver DECLARAR, CAMBIAR Y AGREGAR SERVICIO.")
    sm = sm.replace("para eso esta cambiar_servicio. Si responde ERROR porque la via ya fue elegida con cambiar_servicio",
                    "para eso esta cambiar_servicio. Si responde ERROR porque la via ya fue elegida")
    sm = sm.replace(EJEMPLO_VIEJO, EJEMPLOS_NUEVOS)
    return _mexico(sm)


def _mexico(sm):
    sm = sm.replace(MEXICO_V1, MEXICO_NUEVO).replace(LINEA_MEXICO_VIEJA, MEXICO_NUEVO)
    if "- registrar_destinatario_mexico(" not in sm:
        sm = sm.replace("- agregar_servicio(servicio):", LINEA_HERR_MEXICO + "\n- agregar_servicio(servicio):", 1)
    return sm


# ---------------------------------------------------------------------------------------------------------------
# S4: `Contexto conversacion` exposes the resolver v2 state; each part of a mixed send carries its USD.

_USD_PARTE = ("'usd', CASE WHEN g.destination_currency = 'USD' THEN g.quoted_destination_amount "
              "WHEN cerebro_riel_op(g.id) = 'mexico' THEN round(g.quoted_source_amount / NULLIF((SELECT t.tasa_cup FROM tasas t "
              "WHERE t.moneda = 'usd' ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1), 0), 4) END")


def aplicar_contexto(wf):
    n = _nodo(wf, "Contexto conversacion")
    if n is None:
        raise ValueError("Contexto conversacion not found")
    q = n["parameters"]["query"]
    if "AS servicio_resuelto" in q:
        return wf
    marca = "'moneda', g.destination_currency, 'status', g.status"
    if marca not in q:
        raise ValueError("envio_mixto parts not found")
    q = q.replace(marca, marca + ", " + _USD_PARTE, 1)
    q, k = re.subn(r"\s*FROM conversations v WHERE v\.id = \$1::uuid;?\s*$",
                   ",\n-- S4 (269): the resolver v2 state (operations, declared intent, coverage): the single source of the Decisor's "
                   "service notes.\ncerebro_resolver_servicio(v.id) AS servicio_resuelto\n\nFROM conversations v WHERE v.id = $1::uuid;",
                   q)
    if k != 1:
        raise ValueError("final FROM not found")
    n["parameters"]["query"] = q
    return wf


# ---------------------------------------------------------------------------------------------------------------
# S5b: test without the automatic readers (disabled, never deleted). Re-enable with reactivar_lectores / --lectores on.

LECTORES = ["Registrar beneficiario auto", "Registrar zelle auto", "Registrar destino auto"]


def desactivar_lectores(wf):
    for n in wf["nodes"]:
        if n["name"] in LECTORES:
            n["disabled"] = True
    return wf


def reactivar_lectores(wf):
    for n in wf["nodes"]:
        if n["name"] in LECTORES:
            n.pop("disabled", None)
    return wf


SECCION_SIN_LECTORES = """## SIN LECTORES AUTOMATICOS (manda sobre cualquier otra mencion de registro automatico de este prompt)
El sistema YA NO guarda solo a quien recibe: ni tarjeta y celular, ni cuenta Zelle, ni el destino. Solo el deposito (comprobante) se registra solo. Todo lo demas lo creas TU con tus herramientas, en el MISMO turno en que el cliente da, corrige o confirma el dato:
- tarjeta cubana y/o celular, nombre -> gestionar_beneficiario (uno por llamada); varios beneficiarios con su reparto -> registrar_reparto_multiple.
- cuenta Zelle y/o nombre del titular -> registrar_beneficiario_zelle.
- numeros a recargar -> registrar_numeros_recarga; combo -> registrar_destinatario_combo; visa -> abrir_extension_visa; entrega en efectivo -> registrar_datos_entrega_efectivo; Mexico -> registrar_destinatario_mexico.
- la via en dolares (clasica, tropical, efectivo) -> marcar_destino_usd la primera vez; y el servicio del cliente SIEMPRE con declarar_servicio / cambiar_servicio / agregar_servicio (ver DECLARAR, CAMBIAR Y AGREGAR SERVICIO).
- un solo deposito para varios servicios -> repartir_envio con TODAS las partes cuando el cliente confirme el reparto.
Un dato esta registrado SOLO si el [CONTEXTO] dice 'YA REGISTRADO' o si la herramienta lo confirmo en este turno. Si el [CONTEXTO] dice 'DETECTADOS PERO NO REGISTRADOS', llamas la herramienta. Nunca confirmes al cliente un dato que no guardaste."""

_MARCA_SL = "## SIN LECTORES AUTOMATICOS"
_ANCLA_SL = "## REGLA DE ORO DEL REGISTRO"


def editar_prompt_sin_lectores(sm):
    if _MARCA_SL in sm:
        return sm
    sm = sm.replace("Los numeros escritos se guardan solos. ", "")
    return sm.replace(_ANCLA_SL, SECCION_SIN_LECTORES + "\n\n" + _ANCLA_SL, 1)


def quitar_prompt_sin_lectores(sm):
    if _MARCA_SL not in sm:
        return sm
    i = sm.index(_MARCA_SL)
    j = sm.index(_ANCLA_SL, i)
    sm = sm[:i] + sm[j:]
    return sm.replace("numeros vacio si aun no los dio. Si te dice", "numeros vacio si aun no los dio. Los numeros escritos se guardan solos. Si te dice")


# ---------------------------------------------------------------------------------------------------------------
# S5b follow-up: remove (not only override) the wording that teaches "the system registers the recipient by itself", and add
# the rules measured offline: C1 (Zelle: names and accounts first), M1 (Mexico), M4/F3 (reconcile a deposit), F1 (ademas).

def _cortar(sm, ini, fin, nuevo):
    """Replace sm[ini..fin) (fin exclusive marker kept) by nuevo; raise when a marker is missing so nothing half-applies."""
    i = sm.index(ini)
    j = sm.index(fin, i)
    return sm[:i] + nuevo + sm[j:]


NUEVA_TAREA = ("Los depósitos se registran AUTOMATICAMENTE; lo demas (a quien recibe, el servicio, el reparto) lo guardas TU con tus "
               "herramientas en cuanto el cliente lo dice. Tu trabajo es conversar y guardar con las tools lo que el cliente da. "
               "Aprobaciones y confirmaciones de envio: SOLO el operador humano.")

BLOQUE_ZELLE = """- ZELLE A VARIAS PERSONAS: pide primero el NOMBRE y CUENTA de CADA destinatario (correo o celular de EEUU), antes de hablar de montos; los montos van despues. Una llamada a registrar_beneficiario_zelle por destinatario, con el nombre y la cuenta TAL CUAL los escribio el cliente."""

BLOQUE_RECONCILIAR = """DEPOSITO QUE NO CUADRA CON UN ENVIO DE VARIAS PARTES: si el deposito verificado es distinto del total acordado de las partes (Mexico + efectivo + tarjeta, etc.), no inventes: reconcilia las partes con las cifras del [CONTEXTO] y pregunta cual parte cambia ('Su depósito de *71,200 GYD* cuadra con *100 USD* a México, no con *150*; ¿confirma?'). PROHIBIDO decir que se transfiere el equivalente, PROHIBIDO decir que se ajusta el equivalente, que se envia lo que alcance o que quedas esperando el resto, hasta que el cliente confirme cual parte cambia."""

EJ_NANA_NUEVO = ("C: [Contacto] Nana 5354600210 + 9238 1299 7894 4918 -> [llama gestionar_beneficiario(tarjeta, celular)] 'Anotado quien recibe en "
                 "Cuba: tarjeta *9238 1299 7894 4918* y celular *54600210*. Apenas haga su depósito envíenos la captura por favor.'  "
                 "## tarjeta de contacto: el número vale igual que escrito; primero la herramienta, luego confirmas lo que quedo guardado")

BLOQUE_ADEMAS = ("- 'ademas una recarga' / 'y tambien una recarga' / 'aparte quiero ...' = agregar_servicio('recarga') (o la clave que diga); "
                 "NO declares otra vez ni cambies el servicio que ya tiene.")


def limpiar_registro_automatico(sm):
    if "ZELLE A VARIAS PERSONAS" in sm:
        return sm
    sm = sm.replace(' Cualquier frase de este prompt que diga que "el sistema los registra solo" o "se guardan solos" NO aplica. Solo el deposito', ' Solo el deposito')
    # TAREA: the sentence about the recipient registering itself
    sm = _cortar(sm, "Los depósitos se registran AUTOMATICAMENTE, y el beneficiario TAMBIEN", "\n\n## COMO CALLAR", NUEVA_TAREA)
    # PRIORIDAD: Beneficiario YA REGISTRADO bullet
    sm = _cortar(sm, "- Beneficiario YA REGISTRADO → NO llames gestionar_beneficiario (el sistema ya lo hizo)", "\n- ENVIO A VARIOS BENEFICIARIOS",
                 "- Beneficiario YA REGISTRADO (lo guardaste tu o lo dice el [CONTEXTO]) → no vuelvas a llamar la herramienta con los mismos datos: "
                 "confirma tarjeta y celular COMPLETOS en *negrita* con palabras.")
    sm = sm.replace("pide la tarjeta y el celular como siempre; el sistema los registra solo. Y ADEMAS llama marcar_destino_usd",
                    "pide la tarjeta y el celular como siempre y guardalos con gestionar_beneficiario. Y ADEMAS llama marcar_destino_usd")
    sm = _cortar(sm, "6. Beneficiario que llego escrito, en imagen o en tarjeta de contacto: el sistema ya lo registro", "\n7. Mensajes cortos",
                 "6. Beneficiario que llego escrito, en imagen o en tarjeta de contacto: guardalo TU con gestionar_beneficiario en ese mismo turno y "
                 "confirma tarjeta y celular COMPLETOS en negrita solo cuando la herramienta diga que quedo guardado. Si el cliente ya dijo que va a "
                 "depositar: confirma los datos y cierra con 'Apenas haga su depósito envíenos la captura por favor.'")
    # examples that taught "the system already saved it, call no tool"
    sm = _cortar(sm, "C: [Nota de voz]: 'En un momento le depósito y ahora le paso los datos.' + [imagen de tarjeta; contexto: Beneficiario YA REGISTRADO",
                 "C: [Nota de voz]: 'Ahi le mando el comprobante y los datos de quien recibe.'", "")
    sm = _cortar(sm, "C: [Contacto] Nana 5354600210 + [contexto: Beneficiario YA REGISTRADO", "C: Hola, buenos días, a cómo está el cambio?",
                 EJ_NANA_NUEVO + "\n\n")
    sm = sm.replace("## la tarjeta y el celular los registra el sistema solo, pero TU llamas marcar_destino_usd con 'clasica'. Sin eso se confunde con un envio en CUP",
                    "## TU guardas la tarjeta y el celular con gestionar_beneficiario y llamas marcar_destino_usd con 'clasica'. Sin eso se confunde con un envio en CUP")
    # new rules inside the no-readers section
    sm = sm.replace("- un solo deposito para varios servicios -> repartir_envio",
                    BLOQUE_ZELLE + "\n" + BLOQUE_ADEMAS + "\n- un solo deposito para varios servicios -> repartir_envio", 1)
    sm = sm.replace("\n\n## REGLA DE ORO DEL REGISTRO", "\n" + BLOQUE_RECONCILIAR + "\n\n## REGLA DE ORO DEL REGISTRO", 1)
    # M1: Mexico paragraph starts with the declaration
    sm = sm.replace("- MEXICO: apenas el cliente diga que quiere mandar a Mexico, declarar_servicio('mexico'). Cotiza",
                    "- MEXICO: PRIMERO declarar_servicio('mexico') apenas el cliente diga que quiere mandar a Mexico, antes de cotizar o de pedir datos. Cotiza")
    return sm


# ---------------------------------------------------------------------------------------------------------------
# 274: several Zelle recipients. cerebro_guardar_zelle(conv, nombre, cuenta, exec, p_op, p_tool, posicion, agregar, monto).

DESC_ZELLE = (
    "Guarda o completa un destinatario Zelle: titular (nombre) y cuenta (correo o celular de EEUU, copiado literal). Con UN solo "
    "destinatario acepta datos a medias y una correccion de la misma cuenta. Con VARIOS destinatarios: llamala una vez por persona; "
    "agregar=true agrega a OTRA persona (la misma cuenta que ya existe solo la corrige, nunca la duplica); posicion=k corrige el "
    "destinatario k; monto es el monto en USD de ese destinatario (vacio si no lo dio). Si el envio ya tiene 2 o mas destinatarios y la "
    "cuenta no coincide con ninguno (o con UN destinatario y una cuenta distinta), devuelve 'NO SE GUARDO NADA ...': repite la llamada con agregar=true o con la posicion. Responde "
    "lo guardado y que FALTA; dile al cliente solo eso. Completa SIEMPRE posicion, agregar y monto en cada llamada (vacio cuando no aplican).")


def consulta_zelle():
    return ("-- 274: several Zelle recipients. agregar adds another person, posicion patches slot k, monto is USD for that recipient.\n"
            "SELECT deal_id AS id, accion FROM cerebro_guardar_zelle($1::uuid, NULLIF($2,''), NULLIF($3,''), $4, NULL, "
            "'registrar_beneficiario_zelle', NULLIF($5,'')::int, coalesce(NULLIF($6,'')::boolean,false), NULLIF($7,'')::numeric);")


def reemplazo_zelle():
    return ("={{ [$('Decisor').item.json.conversation_id, "
            "$fromAI('nombre', 'nombre completo del titular de la cuenta Zelle, tal cual lo dio el cliente (cadena vacia si todavia no lo tienes)', 'string'), "
            "$fromAI('cuenta', 'cuenta Zelle: correo o celular de EEUU, COPIADO LITERAL como lo escribio el cliente, sin quitar el +1 ni los parentesis ni los guiones (cadena vacia si todavia no lo tienes)', 'string'), "
            "$execution.id, "
            "$fromAI('posicion', 'numero del destinatario Zelle (1, 2, 3...) cuando CORRIGES uno ya guardado; vacio si no corriges por posicion', 'string'), "
            "$fromAI('agregar', 'true cuando es OTRA persona que se suma a las ya guardadas; false o vacio si completas o corriges la misma', 'string'), "
            "$fromAI('monto', 'monto en USD que recibe ESTE destinatario, solo numero; vacio si el cliente no lo dijo', 'string')] }}")


def aplicar_zelle(wf):
    n = _nodo(wf, "registrar_beneficiario_zelle")
    if n is None:
        raise ValueError("registrar_beneficiario_zelle not found")
    n["parameters"]["query"] = consulta_zelle()
    n["parameters"].setdefault("options", {})["queryReplacement"] = reemplazo_zelle()
    n["parameters"]["toolDescription"] = DESC_ZELLE
    return wf


_ZELLE_LINEA_VIEJA = ("- registrar_beneficiario_zelle(nombre,cuenta): registra al beneficiario de la via ZELLE. La `cuenta` es el correo o el celular de EEUU, "
                      "COPIADO LITERAL como lo escribio el cliente (con su +1, sus parentesis y sus guiones). Llamala en cuanto tengas el NOMBRE o la CUENTA "
                      "(lo otro vacio) y otra vez si el cliente completa o corrige alguno.")
_ZELLE_LINEA_NUEVA = ("- registrar_beneficiario_zelle(nombre, cuenta, posicion, agregar, monto): registra a un destinatario de la via ZELLE. La `cuenta` es el correo o el "
                      "celular de EEUU, COPIADO LITERAL como lo escribio el cliente (con su +1, sus parentesis y sus guiones). Llamala en cuanto tengas el NOMBRE o la "
                      "CUENTA (lo otro vacio) y otra vez si el cliente completa o corrige alguno. Con varios destinatarios: una llamada por persona; agregar=true para "
                      "sumar a otra persona, posicion=k para corregir al destinatario k, monto en USD de ese destinatario si lo dio.")
_ZELLE_BLOQUE_NUEVO = ("- ZELLE A VARIAS PERSONAS: pide primero el NOMBRE y CUENTA de CADA destinatario (correo o celular de EEUU), antes de hablar de montos; los montos van "
                       "despues. Una llamada a registrar_beneficiario_zelle por destinatario, con el nombre y la cuenta TAL CUAL los escribio el cliente: la primera persona "
                       "sin parametros y cada otra con agregar=true. Para corregir a uno ya guardado usa la misma cuenta o posicion=k; el monto de cada uno va en monto (USD). "
                       "Si la respuesta empieza con 'NO SE GUARDO NADA', no confirmes nada: repite la llamada con agregar=true o con la posicion que corresponda. "
                       "Confirma al cliente SOLO lo que la herramienta devuelve en 'Destinatarios Zelle ahora'.")


def editar_prompt_zelle(sm):
    sm = sm.replace(_ZELLE_LINEA_VIEJA, _ZELLE_LINEA_NUEVA)
    if "agregar=true" in sm.split("- ZELLE A VARIAS PERSONAS", 1)[-1][:600]:
        return sm
    return _cortar(sm, "- ZELLE A VARIAS PERSONAS", "\n", _ZELLE_BLOQUE_NUEVO) if "- ZELLE A VARIAS PERSONAS" in sm else sm


# 275: operations are opened from the declared intent; the recipient tools need the declaration first.
BLOQUE_DECLARA_PRIMERO = ("- DECLARA PRIMERO: antes de guardar los datos de quien recibe, llama declarar_servicio con el servicio (mexico, efectivo_usd, zelle, "
                          "clasica, tropical, cuban_card, recarga): la herramienta de datos abre la operacion a partir de lo que declaraste, aunque todavia no haya "
                          "deposito. Sin declarar, las de Mexico y efectivo responden que no hay envio abierto: declara y repite la llamada.")


def editar_prompt_declarar_primero(sm):
    if "DECLARA PRIMERO" in sm:
        return sm
    return sm.replace("- un solo deposito para varios servicios -> repartir_envio", BLOQUE_DECLARA_PRIMERO + "\n- un solo deposito para varios servicios -> repartir_envio", 1)


# 276: marcar_destino_usd targets remesas only (never the Mexico/recarga operation) and accepts 'cup'.
DESC_DESTINO = ("Marca la via de la REMESA abierta: en DOLARES por tarjeta 'clasica' o 'tropical', en 'efectivo' (dolares fisicos en Cuba), o en pesos con "
                "'cup' (tarjeta en pesos). Llamala en cuanto el cliente lo pida. Solo toca remesas: nunca una recarga ni un envio a Mexico. No es para Zelle. "
                "Para CAMBIAR una via ya elegida usa cambiar_servicio.")
FROMAI_DESTINO = "via de entrega que pidio el cliente: clasica, tropical, efectivo o cup (tarjeta en pesos)"


def aplicar_destino(wf):
    n = _nodo(wf, "marcar_destino_usd")
    if n is None:
        raise ValueError("marcar_destino_usd not found")
    r = n["parameters"].setdefault("options", {}).get("queryReplacement", "")
    r = re.sub(r"\$fromAI\('tipo', '[^']*'", "$fromAI('tipo', '" + FROMAI_DESTINO + "'", r)
    n["parameters"]["options"]["queryReplacement"] = r
    n["parameters"]["toolDescription"] = DESC_DESTINO
    return wf


_DESTINO_VIEJO = ("- marcar_destino_usd(tipo): marca la via en DOLARES la PRIMERA vez que el cliente la elige: tarjeta 'clasica' o 'tropical', o 'efectivo' "
                  "(dolares fisicos en Cuba).")
_DESTINO_NUEVO = ("- marcar_destino_usd(tipo): marca la via de la REMESA la PRIMERA vez que el cliente la elige: tarjeta 'clasica' o 'tropical', 'efectivo' "
                  "(dolares fisicos en Cuba) o 'cup' (tarjeta en pesos). Solo toca remesas, nunca una recarga ni Mexico.")
BLOQUE_MIXTO_TARJETA = ("- ENVIO MIXTO CON TARJETA: si hay una remesa y ademas una recarga o Mexico, guarda la tarjeta con gestionar_beneficiario y marca su via con "
                        "marcar_destino_usd: la tarjeta cae en la remesa de esa via; los numeros de la recarga van con registrar_numeros_recarga a su propia operacion. "
                        "No mezcles los datos de un servicio en la operacion de otro.")


def editar_prompt_destino(sm):
    sm = sm.replace(_DESTINO_VIEJO, _DESTINO_NUEVO)
    if "ENVIO MIXTO CON TARJETA" in sm:
        return sm
    return sm.replace("- un solo deposito para varios servicios -> repartir_envio", BLOQUE_MIXTO_TARJETA + "\n- un solo deposito para varios servicios -> repartir_envio", 1)


# 277: planned split before the deposit; facts (not a refusal) on a different deposit.
DESC_REPARTIR = (
    "Reparte UN solo deposito del cliente entre MAS DE UN servicio (por ejemplo una remesa por Clasica y ademas una recarga, o Mexico + efectivo + tarjeta). "
    "Llamala SOLO cuando el cliente confirme las partes. Pasa TODAS las partes, cada una con su servicio y su monto en GYD, por ejemplo \"clasica 18200, recarga 6200\" "
    "o \"mexico 39000, efectivo 29000, cup 15000\". Puedes llamarla ANTES del deposito: queda un reparto planeado y cada parte abre su operacion vacia donde guardar sus "
    "datos; cuando llegue un deposito de exactamente la suma, se reparte solo. Si ya hay un deposito y las partes no suman exactamente lo depositado, responde "
    "'REPARTO NO APLICADO' con las cifras y no cambia nada: pregunta al cliente que parte cambia y vuelve a llamar con montos que sumen exactamente lo depositado. "
    "Servicios: cup (tarjeta en pesos), clasica, tropical, zelle, efectivo, mexico, recarga, combo, visa, saldo movil. NO la uses para cambiar el servicio de un envio unico "
    "(eso es cambiar_servicio). Dile al cliente lo que respondio la tool, sin inventar cifras.")


def aplicar_repartir(wf):
    n = _nodo(wf, "repartir_envio")
    if n is None:
        raise ValueError("repartir_envio not found")
    n["parameters"]["toolDescription"] = DESC_REPARTIR
    return wf


BLOQUE_REPARTO_PREVIO = ("- REPARTO ANTES DEL DEPOSITO: cuando el cliente confirme las partes de un envio con varios servicios (por ejemplo 'mexico 39000, efectivo 29000, cup 15000'), "
                         "llama repartir_envio YA, sin esperar el deposito: queda planeado y cada parte tiene su operacion para guardar sus datos. Si el deposito llega distinto a la suma "
                         "o la herramienta responde 'REPARTO NO APLICADO', no inventes: PREGUNTA al cliente que parte cambia y vuelve a llamar con montos que sumen exactamente lo depositado.")


def editar_prompt_repartir(sm):
    if "REPARTO ANTES DEL DEPOSITO" in sm:
        return sm
    return sm.replace("- un solo deposito para varios servicios -> repartir_envio", BLOQUE_REPARTO_PREVIO + "\n- un solo deposito para varios servicios -> repartir_envio", 1)


# ---------------------------------------------------------------------------------------------------------------
# Overnight step 4 (280-284). One general tool for the operation; extend the tools that own each domain.

DESC_MODIFICAR = (
    "Modifica la OPERACION abierta del cliente (no los datos de quien recibe). accion='monto': cambia lo que deposita el cliente en GYD (valor = numero; "
    "calculalo antes con calcular_usd / calcular_envio, nunca de memoria). accion='cancelar': cancela una operacion que NO tiene dinero (sin deposito ni comprobante); "
    "con dinero responde que una persona lo atiende. accion='unir': junta dos operaciones abiertas del mismo servicio (valor = {\"con\": \"<id>\"} o vacio si solo hay un par). "
    "accion='mover_deposito': mueve un deposito VERIFICADO de la operacion op (la que lo tiene) a otra (valor = {\"a\": \"<id destino>\", \"deposito\": \"<referencia>\"}; "
    "deposito solo si op tiene varios): llamala SOLO despues de que el cliente confirme para cual operacion es ese dinero. "
    "op = id de la operacion; vacio si solo hay una abierta (si hay varias te devuelve la lista: preguntale al cliente a cual y repite con el id). "
    "No parte ni duplica depositos. Devuelve ok, mensaje (en espanol, dile al cliente lo que dice) y motivo si no se pudo.")


def consulta_modificar():
    return ("-- 281: ONE general tool for the operation: monto | cancelar (no money) | unir. The database validates and audits.\n"
            "SELECT cerebro_modificar_operacion($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,'')::jsonb, 'agent:modificar_operacion n8n:' || $5) AS resultado;")


def reemplazo_modificar():
    return ("={{ [$('Decisor').item.json.conversation_id, "
            "$fromAI('op', 'id (uuid) de la operacion a modificar; vacio si solo hay una abierta', 'string', ''), "
            "$fromAI('accion', 'monto, cancelar o unir', 'string'), "
            "$fromAI('valor', 'para monto: el nuevo monto en GYD (solo numero); para unir: {\"con\": \"<id>\"} o vacio; para cancelar: vacio', 'string', ''), "
            "$execution.id] }}")


DESC_GESTIONAR = (
    "Guarda o completa UN beneficiario que recibe en Cuba: tarjeta de 16 digitos, celular cubano de 8 y nombre. Acepta datos a medias; lo que no mandes se conserva; "
    "una tarjeta distinta empieza sin celular. Para CORREGIR un destinatario ya guardado indica posicion (1, 2, 3...) y/o tipo (tarjeta, zelle, efectivo, recarga, mexico) "
    "con el dato corregido: los demas no se tocan. op = id de la operacion cuando hay varias abiertas. Un celular o tarjeta de Zelle, efectivo, recarga o Mexico se guarda "
    "con la herramienta de ese servicio. Responde que quedo guardado y que FALTA.")


def reemplazo_gestionar():
    return ("={{ [$('Decisor').item.json.conversation_id, "
            "$fromAI('nombre', 'nombre del beneficiario que recibe en Cuba, o vacio si no se dijo', 'string'), "
            "$fromAI('tarjeta', 'numero de tarjeta cubana de 16 digitos de quien recibe (cadena vacia si todavia no lo tienes)', 'string'), "
            "$fromAI('celular', 'numero de celular cubano de 8 digitos de quien recibe (cadena vacia si todavia no lo tienes)', 'string'), "
            "$execution.id, "
            "$fromAI('op', 'id de la operacion cuando hay varias abiertas; vacio si no', 'string', ''), "
            "$fromAI('posicion', 'numero del destinatario (1, 2, 3...) SOLO cuando corriges uno ya guardado; vacio si no', 'string', ''), "
            "$fromAI('tipo', 'tipo del destinatario a corregir: tarjeta, zelle, efectivo, recarga o mexico; vacio si no corriges', 'string', '')] }}")


def consulta_gestionar():
    return ("-- 284: corrections by posicion / tipo and the operation the bot names (op).\n"
            "SELECT deal_id AS id, accion FROM cerebro_guardar_beneficiario($1::uuid, NULLIF($2,''), NULLIF($3,''), NULLIF($4,''), $5, NULLIF($6,'')::uuid, "
            "'gestionar_beneficiario', NULLIF($7,'')::int, NULLIF($8,''));")


DESC_CAMBIAR_NOCHE = (
    "El cliente DECIDIO cambiar el servicio o la VIA de ESTE envio por otro: 'zelle', 'clasica', 'tropical', 'cuban_card' (tarjeta en pesos, CUP), 'efectivo_usd' "
    "(dolares fisicos en Cuba), 'recarga', 'combo', 'visa', 'saldo' o 'mexico'. Tambien sirve para ELEGIR la via la primera vez (clasica, tropical, efectivo, cup). Llamala ANTES de "
    "responder. NO la llames si solo pregunta un precio o compara, si habla de otra persona u otro envio, ni para SUMAR un servicio (eso es agregar_servicio). Sin dinero "
    "registrado, las vias se aplican al instante; con deposito la base valida el minimo. Devuelve mensaje (en espanol, para decirselo al cliente), aplicado, permitido, motivo, "
    "minimo_gyd y faltante_gyd.")

DESC_REPARTIR_NOCHE = DESC_REPARTIR.replace(
    "Si ya hay un deposito y las partes no suman exactamente lo depositado, responde 'REPARTO NO APLICADO' con las cifras y no cambia nada: pregunta al cliente que parte cambia y vuelve a llamar con montos que sumen exactamente lo depositado.",
    "Si las partes suman MENOS que el deposito verificado, se aplica un reparto PARCIAL: cada parte debe llegar al minimo de su servicio, las partes no enviadas quedan "
    "pendientes con su operacion y sus datos esperando deposito. Si las partes suman MAS que lo verificado responde 'REPARTO NO APLICADO' con las cifras y no cambia nada: "
    "decide con el cliente que parte cambia o si deposita el resto, y vuelve a llamar.")


def aplicar_noche4(wf):
    base = _nodo(wf, "cambiar_servicio")
    # the general tool for the operation
    mo = _nodo(wf, "modificar_operacion")
    if mo is None:
        mo = copy.deepcopy(base)
        mo["id"] = str(uuid.uuid4())
        mo["name"] = "modificar_operacion"
        mo["position"] = [base["position"][0] + 640, base["position"][1]]
        wf["nodes"].append(mo)
    mo["parameters"]["query"] = consulta_modificar()
    mo["parameters"].setdefault("options", {})["queryReplacement"] = reemplazo_modificar()
    mo["parameters"]["toolDescription"] = DESC_MODIFICAR
    mo["parameters"]["descriptionType"] = "manual"
    mo["notes"] = "281: ONE general tool for the operation (monto | cancelar sin dinero | unir). The database validates, audits and answers in Spanish."
    wf["connections"]["modificar_operacion"] = {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}
    # gestionar_beneficiario: corrections
    gb = _nodo(wf, "gestionar_beneficiario")
    if gb is not None:
        gb["parameters"]["query"] = consulta_gestionar()
        gb["parameters"].setdefault("options", {})["queryReplacement"] = reemplazo_gestionar()
        gb["parameters"]["toolDescription"] = DESC_GESTIONAR
    # cambiar_servicio absorbs marcar_destino_usd (283)
    base["parameters"]["toolDescription"] = DESC_CAMBIAR_NOCHE
    md = _nodo(wf, "marcar_destino_usd")
    if md is not None:
        md["disabled"] = True
    rp = _nodo(wf, "repartir_envio")
    if rp is not None:
        rp["parameters"]["toolDescription"] = DESC_REPARTIR_NOCHE
    return wf


# ---------------------------------------------------------------------------------------------------------------
# Overnight step 4: the prompt REPLACES superseded instructions (marcar_destino_usd, the two deposit blocks) instead of stacking more.

BLOQUE_NO_CUADRA = """DEPOSITO QUE NO CUADRA CON LAS PARTES (envio con varios servicios): el [CONTEXTO] trae los HECHOS (deposito verificado, partes, lo que cubre, lo que falta o sobra); TU decides con el cliente, preguntandole, y usas la herramienta que corresponda:
- aplicar ya lo que el deposito cubre: repartir_envio solo con esas partes (reparto parcial; cada parte debe llegar al minimo de su servicio); las demas quedan pendientes con sus datos esperando deposito.
- esperar el resto del deposito y repartir todo junto cuando llegue (repartir_envio puede llamarse ANTES del deposito: queda planeado).
- cambiar o quitar una parte: modificar_operacion (monto, cancelar sin dinero, unir); un numero de recarga que sobra: registrar_numeros_recarga con accion quitar.
Ejemplo: 'Su depósito de *71,200 GYD* cuadra con *100 USD* a México, no con *150*; ¿lo aplico así, o prefiere esperar el resto?'. PROHIBIDO decir que se transfiere o se ajusta el equivalente, o prometer una entrega, antes de que el cliente decida.
Dinero que el cliente devuelve al negocio (una transferencia doble, un reembolso, una deuda) NO es un envio: no lo metas en un reparto; derivar_humano.
- un solo deposito para varios servicios, con las partes confirmadas -> repartir_envio con TODAS las partes (tambien antes del deposito)."""

LINEA_GESTIONAR_NUEVA = ("- gestionar_beneficiario(nombre, tarjeta, celular, op, posicion, tipo): registra UN beneficiario de tarjeta cubana. Si el [CONTEXTO] dice 'Beneficiario YA REGISTRADO', "
                         "no la llames con los mismos datos. Llamala en cuanto tengas la tarjeta, el celular o el nombre (aunque falte el otro dato), y otra vez si el cliente completa o corrige "
                         "alguno. Para CORREGIR a un destinatario ya guardado di su posicion (1, 2...) o tipo; op solo si hay varias operaciones abiertas.")
LINEA_MODIFICAR = ("- modificar_operacion(op, accion, valor): cambia la OPERACION, no los datos de quien recibe. accion monto (nuevo monto en GYD, calculado con una tool), cancelar "
                   "(solo si NO tiene dinero; con dinero la atiende una persona) o unir (dos operaciones abiertas del mismo servicio). Con varias abiertas pregunta cual al cliente.")


def refinar_prompt_noche4(sm):
    if "DEPOSITO QUE NO CUADRA CON LAS PARTES" in sm:
        return sm
    # 1. the two superseded deposit blocks become one
    sm = _cortar(sm, "- REPARTO ANTES DEL DEPOSITO:", "\n- un solo deposito para varios servicios -> repartir_envio con TODAS", "")
    sm = sm.replace("\n- un solo deposito para varios servicios -> repartir_envio con TODAS las partes cuando el cliente confirme el reparto.", "", 1)
    sm = _cortar(sm, "DEPOSITO QUE NO CUADRA CON UN ENVIO DE VARIAS PARTES:", "\n\n## REGLA DE ORO DEL REGISTRO", BLOQUE_NO_CUADRA)
    # 2. marcar_destino_usd is retired (283): the rail is a service handled by declarar / cambiar
    sm = sm.replace("- la via en dolares (clasica, tropical, efectivo) -> marcar_destino_usd la primera vez; y el servicio del cliente SIEMPRE con declarar_servicio / cambiar_servicio / agregar_servicio",
                    "- el servicio y la via del cliente (zelle, clasica, tropical, efectivo, cup) SIEMPRE con declarar_servicio / cambiar_servicio / agregar_servicio")
    sm = sm.replace("guarda la tarjeta con gestionar_beneficiario y marca su via con marcar_destino_usd: la tarjeta cae en la remesa de esa via;",
                    "declara la via de la remesa y guarda la tarjeta con gestionar_beneficiario: la tarjeta cae en la remesa de esa via;")
    sm = _cortar(sm, "- marcar_destino_usd(tipo):", "\n- declarar_servicio(servicio):", "")
    sm = sm.replace("\n\n- declarar_servicio(servicio):", "\n- declarar_servicio(servicio):", 1)
    sm = sm.replace(" Y ADEMAS llama marcar_destino_usd con 'clasica' o 'tropical'. Sin esa llamada, en el tablero se ve igual que un envio en CUP y nadie sabe que hay que mandar dolares.",
                    " Declara la via con declarar_servicio('clasica' o 'tropical'): sin eso en el tablero se ve igual que un envio en CUP.")
    sm = sm.replace("- SI ES EFECTIVO: llama marcar_destino_usd con 'efectivo' en cuanto el cliente la elija.",
                    "- SI ES EFECTIVO: declarar_servicio('efectivo_usd') en cuanto el cliente la elija.")
    sm = sm.replace("marcar_destino_usd SOLO con una via clara. Si el cliente YA tenia una via (el [CONTEXTO] trae `riel_operacion`) y ahora pide otra, NO uses marcar_destino_usd: es un cambio, ver CAMBIO DE VIA.",
                    "Declara o cambia la via SOLO con una via clara. Si el cliente YA tenia una via (el [CONTEXTO] trae `riel_operacion`) y ahora pide otra, es un cambio: cambiar_servicio.")
    sm = sm.replace("PROHIBIDO usar calcular_usd, calcular_usd_desde_gyd o marcar_destino_usd para hacer un cambio.",
                    "PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para hacer un cambio.")
    sm = sm.replace("y llamas marcar_destino_usd con 'clasica'. Sin eso se confunde con un envio en CUP", "y declaras la via con declarar_servicio('clasica'). Sin eso se confunde con un envio en CUP")
    sm = sm.replace("## marcar_destino_usd solo con UNA via clara", "## la via se declara solo con UNA via clara")
    # 3. tools list
    sm = _cortar(sm, "- gestionar_beneficiario(nombre,tarjeta,celular):", "\n- registrar_reparto_multiple(", LINEA_GESTIONAR_NUEVA)
    sm = sm.replace("- registrar_numeros_recarga(numeros): llamala EN CUANTO", "- registrar_numeros_recarga(numeros, accion): llamala EN CUANTO", 1)
    sm = sm.replace("numeros vacio si aun no los dio. Si te dice que falta alguno, pideselo.",
                    "numeros vacio si aun no los dio. Con accion quitar saca los numeros que el cliente ya no quiere. Si te dice que falta alguno, pideselo.", 1)
    sm = sm.replace("- cambiar_servicio(servicio): el cliente DECIDIO cambiar el servicio de este envio por otro (mismas claves). La base valida el deposito y ejecuta.",
                    "- cambiar_servicio(servicio): el cliente DECIDIO cambiar el servicio o la via de este envio por otro (mismas claves, incluidas las vias clasica, tropical, efectivo_usd y cuban_card). La base valida el deposito y ejecuta.", 1)
    sm = sm.replace("\n- agregar_servicio(servicio):", "\n" + LINEA_MODIFICAR + "\n- agregar_servicio(servicio):", 1)
    return sm


# ---------------------------------------------------------------------------------------------------------------
# Overnight step 6 (measurement s5b2): replace, do not stack.

P6_DECLARAR = ("- DECLARAR: en cuanto el cliente diga que servicio quiere, llama declarar_servicio(servicio) con una clave concreta ('quiero una recarga', 'mandar a Mexico', 'por Zelle') "
               "EN EL MISMO TURNO, aunque tambien vayas a cotizar: cotiza y declara en ese mismo turno, y solo despues pide datos (declarar va ANTES de pedir datos y de que deposite). "
               "Si dice solo 'enviar dinero a Cuba' sin via, no declares: preguntale la via. Si despues elige otra, declara de nuevo (vale la ultima). Si devuelve ok=false, no se lo "
               "menciones al cliente y sigue.")

P6_ZELLE = ("- ZELLE A VARIAS PERSONAS: pide primero el NOMBRE y CUENTA de CADA destinatario (correo o celular de EEUU), antes de hablar de montos. Una llamada a "
            "registrar_beneficiario_zelle por destinatario, con nombre y cuenta TAL CUAL: la primera persona sin parametros y OTRA persona con agregar=true. Si el cliente da el monto de cada "
            "uno, va en monto (USD) en la llamada de ese destinatario. Para corregir a uno ya guardado usa la misma cuenta o posicion=k. Si la herramienta pregunta si es otra persona o una "
            "correccion ('¿es otra persona o una correccion?') o responde 'NO SE GUARDO NADA', no confirmes nada: pregunta al cliente cual es, nunca adivines, y repite la llamada con "
            "agregar=true o con la posicion. Confirma al cliente SOLO lo que la herramienta devuelve en 'Destinatarios Zelle ahora'.")

P6_QUITAR = ("- QUITAR UN NUMERO: si el cliente dice 'quita ese numero', 'ese no' o 'sin el segundo', llama registrar_numeros_recarga con accion=quitar y SOLO ese numero; "
             "nunca lo vuelvas a agregar.")

P6_MODIFICAR = ("- modificar_operacion(op, accion, valor): cambia la OPERACION, no los datos de quien recibe. accion monto: el cliente cambia el importe de un envio abierto "
                "('mejor 150', 'que sean 200 USD'): calcula el nuevo monto en GYD con calcular_usd / calcular_envio y llama modificar_operacion(accion monto), no vuelvas a cotizar sin llamarla; "
                "cancelar (solo si NO tiene dinero; con dinero la atiende una persona) o unir (dos operaciones abiertas del mismo servicio). Con varias abiertas pregunta cual al cliente.")

P6_MEXICO_INI = "- MEXICO: PRIMERO declarar_servicio('mexico') apenas el cliente diga que quiere mandar a Mexico, antes de cotizar o de pedir datos. Cotiza con"
P6_MEXICO_NUEVO = ("- MEXICO: declarar_servicio('mexico') apenas el cliente diga que quiere mandar a Mexico, y en el mismo mensaje en que declaras y cotizas (calcular_usd / "
                   "calcular_usd_desde_gyd con via=mexico, nunca de memoria) pidele, en un solo mensaje, la cuenta bancaria: CLABE (18 digitos exactos), banco (Mercado Pago, Banco Azteca...) "
                   "y titular; o el retiro sin tarjeta: Coppel o BBVA (multiplos de 100), nombre completo de quien recibe y su telefono. Un monto suelto como '15 mil por transferencia' es "
                   "ambiguo: pregunta si es CUP o GYD. ")


def refinar_prompt_paso6(sm):
    if "EN EL MISMO TURNO, aunque tambien vayas a cotizar" in sm:
        return sm
    sm = _cortar(sm, "- DECLARAR: en cuanto", "\n", P6_DECLARAR)
    sm = _cortar(sm, "- ZELLE A VARIAS PERSONAS:", "\n", P6_ZELLE)
    sm = _cortar(sm, "- modificar_operacion(op, accion, valor):", "\n", P6_MODIFICAR)
    # México: keep the data/registration tail, replace the head up to the ask for data
    i = sm.index(P6_MEXICO_INI)
    j = sm.index("En cuanto tengas la CLABE completa", i)
    sm = sm[:i] + P6_MEXICO_NUEVO + sm[j:]
    # quitar: one line next to the Zelle block
    sm = sm.replace("\n" + P6_ZELLE, "\n" + P6_ZELLE + "\n" + P6_QUITAR, 1)
    return sm


# Transcription spelling hints: business admin names ("Lia" was heard for Eliaba).
NOMBRES_ADMIN = "Eliaba, Osmany"


def aplicar_transcripcion(wf):
    n = _nodo(wf, "Transcribir audio")
    if n is None:
        raise ValueError("Transcribir audio not found")
    for par in n["parameters"]["bodyParameters"]["parameters"]:
        if par.get("name") == "prompt" and NOMBRES_ADMIN not in par["value"]:
            par["value"] = par["value"].replace("MMG, Pay Merchant, Cash In, agente,", "MMG, Pay Merchant, Cash In, agente, " + NOMBRES_ADMIN + ",", 1)
    return wf


# 287: the bot may move a verified deposit between operations, only after the customer confirms which operation the money is for.
P7_MODIFICAR = ("- modificar_operacion(op, accion, valor): cambia la OPERACION, no los datos de quien recibe. accion monto: el cliente cambia el importe de un envio abierto "
                "('mejor 150', 'que sean 200 USD'): calcula el nuevo monto en GYD con calcular_usd / calcular_envio y llama modificar_operacion(accion monto), no vuelvas a cotizar sin llamarla; "
                "cancelar (solo si NO tiene dinero; con dinero la atiende una persona); unir (dos operaciones abiertas del mismo servicio); mover_deposito (un deposito verificado "
                "va a otra operacion, valor {\"a\": id destino}): preguntale al cliente para cual operacion es ese dinero y llamala SOLO cuando lo confirme. Con varias abiertas pregunta cual al cliente.")


def refinar_prompt_mover(sm):
    if "mover_deposito" in sm:
        return sm
    return _cortar(sm, "- modificar_operacion(op, accion, valor):", "\n", P7_MODIFICAR)
