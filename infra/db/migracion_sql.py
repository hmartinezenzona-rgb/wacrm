#!/usr/bin/env python3
"""Ayudante de produccion-migracion.sh: lee las migraciones y compara inventarios.

  migracion_sql.py objetos <mig.sql>...          -> lineas  fn|tbl <TAB> nombre <TAB> evento <TAB> migracion
  migracion_sql.py previa <staging.tsv> <prod.tsv> <nombres_fn.txt> <diff.txt>
  migracion_sql.py verificar <staging.tsv> <prod.tsv> <owners.tsv>

Los .tsv son filas  kind <TAB> key <TAB> md5 <TAB> md5_normalizado <TAB> cuerpo_base64
(las produce la consulta INVENTARIO de produccion-migracion.sh en ambas bases).
Se ejecuta con `python3 -I`: solo biblioteca estandar.
"""
import base64
import difflib
import os
import re
import sys

NOMBRE = r'("?\w+"?(?:\."?\w+"?)?)'
RE_FN = re.compile(
    r'\b(CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION|DROP\s+FUNCTION(?:\s+IF\s+EXISTS)?|ALTER\s+FUNCTION)\s+'
    + NOMBRE + r'\s*\(', re.I)
RE_TBL = re.compile(
    r'\b(?:CREATE\s+(?:UNLOGGED\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?'
    r'|ALTER\s+TABLE(?:\s+ONLY)?(?:\s+IF\s+EXISTS)?'
    r'|DROP\s+TABLE(?:\s+IF\s+EXISTS)?'
    r'|CREATE\s+(?:UNIQUE\s+)?INDEX(?:\s+CONCURRENTLY)?(?:\s+IF\s+NOT\s+EXISTS)?\s+\S+\s+ON(?:\s+ONLY)?'
    r'|CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\s+\S+[^;]*?\s+ON'
    r'|DROP\s+TRIGGER(?:\s+IF\s+EXISTS)?\s+\S+\s+ON)\s+' + NOMBRE, re.I)
RE_VIEW = re.compile(
    r'\b(CREATE\s+(?:OR\s+REPLACE\s+)?VIEW|DROP\s+VIEW(?:\s+IF\s+EXISTS)?)\s+' + NOMBRE, re.I)
SEGURO = re.compile(r'^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$')


def sin_comentarios(sql):
    sql = re.sub(r'/\*.*?\*/', ' ', sql, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', sql)


def calificado(nombre):
    n = nombre.replace('"', '').lower()
    return n if '.' in n else 'public.' + n


def objetos(rutas):
    for ruta in rutas:
        mig = os.path.basename(ruta)[:-4]
        sql = sin_comentarios(open(ruta, encoding='utf-8').read())
        eventos = []
        for m in RE_FN.finditer(sql):
            ev = m.group(1).split()[0].lower()
            eventos.append((m.start(), 'fn', calificado(m.group(2)), ev))
        for m in RE_TBL.finditer(sql):
            eventos.append((m.start(), 'tbl', calificado(m.group(1)), 'toca'))
        for m in RE_VIEW.finditer(sql):
            eventos.append((m.start(), 'view', calificado(m.group(2)), m.group(1).split()[0].lower()))
        for _, tipo, nombre, ev in sorted(eventos):
            if SEGURO.match(nombre):
                print('\t'.join((tipo, nombre, ev, mig)))


def leer(ruta):
    filas = {}
    with open(ruta, encoding='utf-8') as f:
        for linea in f:
            p = linea.rstrip('\n').split('\t')
            if len(p) == 5:
                filas[(p[0], p[1])] = (p[2], p[3], base64.b64decode(p[4]).decode('utf-8', 'replace'))
    return filas


def estado(s, p):
    if s is None:
        return 'EXTRA-IN-PROD'
    if p is None:
        return 'MISSING-IN-PROD'
    if s[0] == p[0]:
        return 'EQUAL'
    return 'EQUAL-NORMALIZED' if s[1] == p[1] else 'DIFFERENT'


def previa(f_stg, f_prod, f_nombres, f_diff):
    stg, prod = leer(f_stg), leer(f_prod)
    nombres = [l.strip() for l in open(f_nombres) if l.strip()]
    claves = sorted(set(stg) | set(prod), key=lambda k: (k[0] != 'fn', k))
    iguales_tabla, iguales_vista, malas, diferentes = 0, 0, 0, []
    for k in claves:
        est = estado(stg.get(k), prod.get(k))
        if k[0] == 'view' and est == 'EQUAL':
            iguales_vista += 1
            continue
        if k[0] != 'fn' and est == 'EQUAL':
            iguales_tabla += 1
            continue
        print('%-16s %-4s %s' % (est, k[0], k[1]))
        if est in ('DIFFERENT', 'MISSING-IN-PROD', 'EXTRA-IN-PROD'):
            malas += 1
        if est == 'DIFFERENT':
            diferentes.append(k)
    vistos = {k[1].split('(')[0] for k in claves if k[0] == 'fn'}
    for n in nombres:
        if n not in vistos:
            print('%-16s %-4s %s (no existe ni en staging previo ni en produccion)' % ('NEW', 'fn', n))
    if iguales_tabla:
        print('(%d columnas/constraints/triggers/indices de tablas tocadas, iguales)' % iguales_tabla)
    if iguales_vista:
        print('(%d vistas, iguales)' % iguales_vista)
    if diferentes:
        with open(f_diff, 'w', encoding='utf-8') as d:
            for k in diferentes:
                d.write('=== %s %s\n' % k)
                d.writelines(difflib.unified_diff(
                    stg[k][2].splitlines(True), prod[k][2].splitlines(True),
                    'staging-previo', 'produccion', lineterm='\n'))
                d.write('\n')
        print('diff: ' + f_diff)
    if malas == 0:
        print('VEREDICTO: SEGURO')
        return 0
    print('VEREDICTO: REVISAR (%d diferencias)' % malas)
    return 1


def verificar(f_stg, f_prod, f_owners, f_views=''):
    stg, prod = leer(f_stg), leer(f_prod)
    owners = {}
    for l in open(f_owners):
        n, o = l.rstrip('\n').split('\t')
        owners[n] = o
    view_owners = {}
    if f_views and os.path.exists(f_views):
        for l in open(f_views):
            n, o = l.rstrip('\n').split('\t')
            view_owners[n] = o
    filas = []
    for n, o in sorted(owners.items()):
        claves = sorted(k for k in set(stg) | set(prod) if k[0] == 'fn' and k[1].split('(')[0] == n)
        if not claves:
            filas.append((n + '(?)', o, 'MISSING-IN-PROD', '-', '-'))
        for k in claves:
            s, p = stg.get(k), prod.get(k)
            filas.append((k[1], o, estado(s, p), (p or ('-',))[0][:8], (s or ('-',))[0][:8]))
    for n, o in sorted(view_owners.items()):
        claves = sorted(k for k in set(stg) | set(prod) if k[0] == 'view' and k[1] == n)
        if not claves:
            filas.append((n + '(?)', o, 'MISSING-IN-PROD', '-', '-'))
        for k in claves:
            s, p = stg.get(k), prod.get(k)
            filas.append((k[1], o, estado(s, p), (p or ('-',))[0][:8], (s or ('-',))[0][:8]))
    if not filas:
        print('VERIFICADO: 0/0 iguales')
        return 0
    filas = [(f[0] if len(f[0]) <= 80 else f[0][:77] + '...',) + f[1:] for f in filas]
    ancho = max(len(f[0]) for f in filas)
    ow = max(len(f[1]) for f in filas)
    for key, o, est, mp, ms in filas:
        print('%-*s  %-*s  %-16s prod=%s stg=%s' % (ancho, key, ow, o, est, mp, ms))
    buenas = sum(1 for f in filas if f[2] == 'EQUAL')
    if buenas == len(filas):
        print('VERIFICADO: %d/%d iguales' % (buenas, len(filas)))
        return 0
    print('NO VERIFICADO: %d/%d iguales' % (buenas, len(filas)))
    return 1


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'objetos':
        objetos(args)
    elif cmd == 'previa':
        sys.exit(previa(*args))
    elif cmd == 'verificar':
        sys.exit(verificar(*args))
    else:
        sys.exit(2)
