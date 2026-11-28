#!/usr/bin/env python3
"""Investiga una conversacion de WaCRM en produccion (solo lectura) o staging.

  conversacion.py <consulta> [--staging] [--desde YYYY-MM-DD] [--mensajes N] [--elegir N]

<consulta>: prefijo hex de id de conversacion (>=6, con digitos y letras a-f),
telefono (solo digitos, >=6) o fragmento de nombre de contacto (letras, >=3).
Corre psql dentro de docker (imagen postgres:17). La URL viaja solo en --env-file;
la consulta viaja solo por stdin como variable psql validada.
Codigos de salida: 0 ok o lista de coincidencias, 1 sin coincidencias, 2 error.
Solo stdlib de Python 3.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

IMAGEN = 'postgres:17'
RAIZ = Path(os.environ.get('WACRM_RAIZ') or Path(__file__).resolve().parents[2])
ENV_PROD = Path.home() / '.config' / 'wacrm' / 'prod-db.env'
ENV_STAGING = RAIZ / '.env.staging'
VAR_PROD = 'PROD_DATABASE_URL'
VAR_STAGING = 'CRM_STAGING_DATABASE_URL'
LIMITE_CONVERSACIONES = 20
MENSAJES_DEFECTO = 40
MENSAJES_MAX = 500
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
FECHA = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}')
URL_EN_TEXTO = re.compile(r'postgres(?:ql)?://\S+')


class Error(Exception):
    def __init__(self, mensaje, codigo=2):
        super().__init__(mensaje)
        self.codigo = codigo


def clasificar(consulta):
    q = consulta.strip()
    if re.fullmatch(r'[0-9]{6,}', q):
        return 'telefono', q
    if (re.fullmatch(r'[0-9a-fA-F]{6,}', q) and re.search(r'[0-9]', q)
            and re.search(r'[a-fA-F]', q)):
        return 'id', q.lower()
    if re.fullmatch(r'[^\W\d_]+(?: [^\W\d_]+)*', q) and len(q.replace(' ', '')) >= 3:
        return 'nombre', q
    raise Error('consulta no admitida: usa un prefijo hex de id (>=6), '
                'un telefono (>=6 digitos) o un nombre (>=3 letras)')


def filtro_sql(tipo):
    # Fragmentos fijos; el valor del usuario entra solo como psql :'q'.
    return {
        'id': "left(c.id::text, length(:'q')) = :'q'",
        'telefono': r"regexp_replace(coalesce(ct.phone,''), '\D', '', 'g') like '%' || :'q' || '%'",
        'nombre': ("translate(lower(coalesce(ct.name,'')), 'áéíóúüñ', 'aeiouun') "
                   "like '%' || translate(lower(:'q'), 'áéíóúüñ', 'aeiouun') || '%'"),
    }[tipo]


def limpio(expr):
    """Texto libre sin separadores ni saltos de linea para la salida de psql."""
    return f"regexp_replace(coalesce({expr}, ''), '[|\\r\\n]+', ' ', 'g')"


def ops_de():
    return "(select id from remittance_operations where conversation_id = :'cid'::uuid)"


def sql_conversaciones(tipo):
    return (
        '\\echo @@CONVERSACIONES\n'
        f"select c.id, {limpio('ct.name')}, coalesce(ct.phone,''), c.status, "
        "coalesce(to_char(c.last_message_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'),''), "
        "case when c.deleted_at is not null then 'borrada' else '' end "
        "from conversations c left join contacts ct on ct.id = c.contact_id "
        f"where {filtro_sql(tipo)} "
        f"order by c.last_message_at desc nulls last limit {LIMITE_CONVERSACIONES};\n"
    )


def sql_detalle(cid, mensajes, desde):
    ops = ops_de()
    return (
        f"\\set cid '{cid}'\n"
        f"\\set n {int(mensajes)}\n"
        f"\\set desde '{desde}'\n"
        '\\echo @@MESSAGES\n'
        "select to_char(x.created_at at time zone 'UTC', 'MM-DD HH24:MI'), x.sender_type, "
        "case when x.content_text is null then '[media]' "
        f"else left({limpio('x.content_text')}, 160) end "
        "from (select * from messages where conversation_id = :'cid'::uuid "
        "and (created_at at time zone 'UTC')::date >= :'desde'::date "
        "order by created_at desc limit :n) x order by x.created_at;\n"
        '\\echo @@OPERATIONS\n'
        "select left(o.id::text, 8), coalesce(o.service_type,''), coalesce(o.delivery_method,''), "
        "o.status, coalesce(o.quoted_source_amount::text,''), coalesce(o.source_currency,''), "
        "coalesce(o.quoted_destination_amount::text,''), coalesce(o.destination_currency,''), "
        "coalesce(left(o.mixed_group_id::text, 8),''), "
        "to_char(o.created_at at time zone 'UTC', 'MM-DD HH24:MI'), "
        "coalesce(to_char(o.completed_at at time zone 'UTC', 'MM-DD HH24:MI'),'') "
        "from remittance_operations o where o.conversation_id = :'cid'::uuid "
        "order by o.created_at;\n"
        '\\echo @@BENEFICIARIES\n'
        "select left(b.operation_id::text, 8), coalesce(b.beneficiary_type,''), "
        f"{limpio('b.name')}, "
        "case when b.card_number is null then '' "
        "else right(regexp_replace(b.card_number, '\\D', '', 'g'), 4) end, "
        f"{limpio('b.phone')}, {limpio('b.zelle_account')}, "
        "coalesce(b.amount::text,''), coalesce(b.currency,''), b.status, coalesce(b.source,'') "
        f"from remittance_beneficiaries b where b.operation_id in {ops} "
        "order by b.operation_id, b.position;\n"
        '\\echo @@AUDIT\n'
        "select to_char(a.created_at at time zone 'UTC', 'MM-DD HH24:MI'), a.action, "
        "coalesce(a.field_name,''), coalesce(a.actor,''), "
        "left(regexp_replace(regexp_replace(coalesce(a.after::text,''), '[|\\r\\n]+', ' ', 'g'), "
        "'(^|[^0-9A-Za-z-])[0-9]( ?[0-9]){12,18}([^0-9A-Za-z-]|$)', '\\1[num]\\3', 'g'), 120) "
        "from remittance_admin_audit a where a.row_id in "
        f"(select id from remittance_operations where conversation_id = :'cid'::uuid "
        "union select b.id from remittance_beneficiaries b where b.operation_id in "
        f"{ops}) order by a.created_at;\n"
        '\\echo @@DEPOSITS\n'
        "select d.trans_id, coalesce(d.monto::text,''), coalesce(d.moneda,''), "
        "case when d.anulado_en is not null then 'anulado' "
        "when d.consumido_en is not null then 'consumido' else 'libre' end, "
        "left(d.operation_id::text, 8) "
        f"from depositos_mmg d where d.operation_id in {ops} order by d.recibido_en;\n"
        '\\echo @@CALCULATOR\n'
        "select left(e.operation_id::text, 8), coalesce(e.entry_date::text,''), "
        "coalesce(e.service,''), e.status, coalesce(e.amount::text,''), "
        "coalesce(e.amount_currency,''), coalesce(e.basis_gyd::text,''), "
        "coalesce(e.facturado_gyd::text,''), coalesce(e.invertido_gyd::text,''), "
        "coalesce(e.retorno_gyd::text,''), "
        "case when e.voided_at is not null then 'void: ' || replace(coalesce(left(e.void_reason, 60), ''), '|', '/') "
        "when e.deleted_at is not null then 'borrada' else '' end "
        f"from remittance_calculator_entries e where e.operation_id in {ops} "
        "order by e.created_at;\n"
        '\\echo @@MANUAL\n'
        # Manual lines typed in the Calculator on the same days as this
        # conversation's operations: they have no operation_id, so they never
        # show up in the block above.
        "select coalesce(e.entry_date::text,''), coalesce(e.service,''), "
        "coalesce(e.amount::text,''), coalesce(e.amount_currency,''), "
        "coalesce(e.facturado_gyd::text,''), coalesce(e.invertido_gyd::text,''), "
        f"coalesce(e.retorno_gyd::text,''), {limpio('e.customer_name')}, coalesce(e.status,'') "
        "from remittance_calculator_entries e "
        "where e.source = 'manual' and e.deleted_at is null "
        "and e.entry_date in (select (o.completed_at at time zone 'America/Guyana')::date "
        f"from remittance_operations o where o.id in {ops} and o.completed_at is not null) "
        "order by e.entry_date, e.created_at;\n"
        '\\echo @@TOOLS\n'
        "select to_char(t.created_at at time zone 'UTC', 'MM-DD HH24:MI'), "
        f"coalesce(t.tool_name,''), {limpio('t.outcome')} "
        "from tool_execution_log t where t.conversation_id = :'cid'::uuid "
        "order by t.created_at;\n"
    )


def psql(env, var, sql):
    cmd = ['docker', 'run', '--rm', '-i', '--env-file', str(env), IMAGEN, 'sh', '-c',
           f'psql -X -q -A -t -F "|" "${var}" -v ON_ERROR_STOP=1 -f -']
    try:
        r = subprocess.run(cmd, input=sql.encode('utf-8'), capture_output=True, timeout=120)
    except OSError:
        raise Error('no se pudo ejecutar docker')
    except subprocess.TimeoutExpired:
        raise Error('tiempo agotado consultando la base')
    if r.returncode != 0:
        lineas = URL_EN_TEXTO.sub('[url]', r.stderr.decode('utf-8', 'replace')).strip().splitlines()
        detalle = lineas[-1] if lineas else f'codigo {r.returncode}'
        raise Error(f'psql fallo: {detalle}')
    return r.stdout.decode('utf-8', 'replace')


def parsear(salida):
    secciones = {}
    actual = None
    for linea in salida.splitlines():
        if linea.startswith('@@'):
            actual = linea[2:].strip()
            secciones.setdefault(actual, [])
        elif actual and linea.strip():
            secciones[actual].append(linea.split('|'))
    return secciones


def enmascarar(celda):
    """Segunda capa: ningun numero de 13-19 digitos (tarjeta) sale completo."""
    return re.sub(r'(?<![0-9A-Za-z-])[0-9](?: ?[0-9]){12,18}(?![0-9A-Za-z-])', '[num]', celda)


def tabla(titulo, cabeceras, filas, mascara=True):
    print(f'== {titulo} ({len(filas)})')
    if not filas:
        print('  (sin filas)\n')
        return
    filas = [[enmascarar(v) if mascara else v for v in (list(f) + [''] * len(cabeceras))[:len(cabeceras)]]
              for f in filas]
    anchos = [max([len(c)] + [len(f[i]) for f in filas]) for i, c in enumerate(cabeceras)]
    print('  ' + '  '.join(c.ljust(a) for c, a in zip(cabeceras, anchos)).rstrip())
    for f in filas:
        print('  ' + '  '.join(v.ljust(a) for v, a in zip(f, anchos)).rstrip())
    print()


def unir(monto, moneda):
    return f'{monto} {moneda}'.strip()


def mostrar_detalle(sec):
    tabla('MESSAGES', ['FECHA HORA UTC', 'REMITE', 'TEXTO'], sec.get('MESSAGES', []))
    tabla('OPERATIONS',
          ['ID', 'SERVICIO', 'ENTREGA', 'ESTADO', 'ORIGEN', 'DESTINO', 'GRUPO', 'CREADA', 'COMPLETADA'],
          [[f[0], f[1], f[2], f[3], unir(f[4], f[5]), unir(f[6], f[7]), f[8], f[9], f[10]]
           for f in sec.get('OPERATIONS', []) if len(f) >= 11])
    tabla('BENEFICIARIES',
          ['OP', 'TIPO', 'NOMBRE', 'TARJETA', 'TELEFONO', 'ZELLE', 'MONTO', 'ESTADO', 'ORIGEN'],
          [[f[0], f[1], f[2], f'****{f[3]}' if f[3] else '', f[4], f[5], unir(f[6], f[7]), f[8], f[9]]
           for f in sec.get('BENEFICIARIES', []) if len(f) >= 10])
    tabla('AUDIT', ['FECHA HORA UTC', 'ACCION', 'CAMPO', 'ACTOR', 'DESPUES'], sec.get('AUDIT', []))
    tabla('DEPOSITS', ['TRANS_ID', 'MONTO', 'MONEDA', 'ESTADO', 'OP'], sec.get('DEPOSITS', []), mascara=False)
    tabla('CALCULATOR',
          ['OP', 'FECHA', 'SERVICIO', 'ESTADO', 'MONTO', 'BASE_GYD', 'FACTURADO', 'INVERTIDO', 'RETORNO', 'NOTA'],
          [[f[0], f[1], f[2], f[3], unir(f[4], f[5]), f[6], f[7], f[8], f[9], f[10]]
           for f in sec.get('CALCULATOR', []) if len(f) >= 11])
    tabla('CALCULADORA MANUAL (mismas fechas)',
          ['FECHA', 'SERVICIO', 'MONTO', 'FACTURADO', 'INVERTIDO', 'RETORNO', 'CLIENTE', 'ESTADO'],
          [[f[0], f[1], unir(f[2], f[3]), f[4], f[5], f[6], f[7], f[8]]
           for f in sec.get('MANUAL', []) if len(f) >= 9])
    tabla('TOOLS', ['FECHA HORA UTC', 'HERRAMIENTA', 'RESULTADO'], sec.get('TOOLS', []))


def validar_fecha(valor):
    if valor is None:
        return '1900-01-01'
    if not FECHA.fullmatch(valor):
        raise Error('--desde debe ser YYYY-MM-DD')
    try:
        return datetime.date.fromisoformat(valor).isoformat()
    except ValueError:
        raise Error('--desde no es una fecha valida')


def correr(args):
    tipo, q = clasificar(args.consulta)
    desde = validar_fecha(args.desde)
    if not 1 <= args.mensajes <= MENSAJES_MAX:
        raise Error(f'--mensajes debe estar entre 1 y {MENSAJES_MAX}')
    env, var = (ENV_STAGING, VAR_STAGING) if args.staging else (ENV_PROD, VAR_PROD)
    if not env.is_file():
        raise Error(f'falta el fichero de entorno {env}')
    if shutil.which('docker') is None:
        raise Error('docker no esta disponible en PATH')

    previo = f"\\set q '{q}'\n"
    sec = parsear(psql(env, var, previo + sql_conversaciones(tipo)))
    filas = [f for f in sec.get('CONVERSACIONES', []) if len(f) >= 6]
    if not filas:
        print(f'Sin coincidencias para la consulta ({tipo}).')
        return 1
    tabla('CONVERSATIONS', ['ID', 'CONTACTO', 'TELEFONO', 'ESTADO', 'ULTIMO UTC', 'NOTA'],
          [[f[0][:8], f[1], f[2], f[3], f[4], f[5]] for f in filas])

    if len(filas) > 1 and args.elegir is None:
        print(f'{len(filas)} conversaciones coinciden. Repite con --elegir N (1-{len(filas)}).')
        return 0
    indice = (args.elegir or 1) - 1
    if not 0 <= indice < len(filas):
        raise Error(f'--elegir debe estar entre 1 y {len(filas)}')
    cid = filas[indice][0]
    if not UUID.fullmatch(cid):
        raise Error('id de conversacion inesperado')

    print(f'Conversacion {cid[:8]} ({filas[indice][1]}).\n')
    mostrar_detalle(parsear(psql(env, var, sql_detalle(cid, args.mensajes, desde))))
    return 0


def construir_parser():
    p = argparse.ArgumentParser(description='Investiga una conversacion de WaCRM (solo lectura).')
    p.add_argument('consulta', help='prefijo de id (hex), telefono (digitos) o nombre')
    p.add_argument('--staging', action='store_true', help='usar .env.staging en vez de produccion')
    p.add_argument('--desde', help='solo mensajes desde esta fecha UTC (YYYY-MM-DD)')
    p.add_argument('--mensajes', type=int, default=MENSAJES_DEFECTO,
                   help=f'ultimos N mensajes (defecto {MENSAJES_DEFECTO})')
    p.add_argument('--elegir', type=int, help='indice 1-based cuando hay varias coincidencias')
    return p


def main(argv=None):
    args = construir_parser().parse_args(argv)
    try:
        return correr(args)
    except Error as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return e.codigo


if __name__ == '__main__':
    sys.exit(main())
