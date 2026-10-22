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
    return ("-- RECARGAS (95, 3-oct-2026): guarda los numeros de Cuba a recargar (uno por recarga) que el cliente dijo,\n"
            "-- tambien por AUDIO. Los escritos ya los guarda la base sola (201). Devuelve cuantos faltan.\n"
            "-- (99) p_abrir: the agent understood a recharge (also by audio): it opens it even before any number.\n"
            "-- (268/269) p_actor: the real actor of the agent's call.\n"
            "SELECT crm_registrar_numeros_recarga($1::uuid, $2, p_abrir => true, "
            "p_actor => 'agent:registrar_numeros_recarga') AS resultado;")


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
    num = _nodo(wf, "registrar_numeros_recarga")
    if num is None:
        raise ValueError("registrar_numeros_recarga not found")
    num["parameters"]["query"] = consulta_numeros()
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
El sistema YA NO guarda solo a quien recibe: ni tarjeta y celular, ni cuenta Zelle, ni el destino. Cualquier frase de este prompt que diga que "el sistema los registra solo" o "se guardan solos" NO aplica. Solo el deposito (comprobante) se registra solo. Todo lo demas lo creas TU con tus herramientas, en el MISMO turno en que el cliente da, corrige o confirma el dato:
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
