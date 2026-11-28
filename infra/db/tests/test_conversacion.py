#!/usr/bin/env python3
"""Pruebas de infra/db/conversacion.py con un docker postizo en PATH.

El postizo guarda argv y stdin de cada llamada y responde con ficheros canned.
Nada toca Docker ni una base de datos de verdad.
Ejecutar: python3 -m unittest discover -s infra/db/tests
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'conversacion.py'
UUID = 'f8b7779c-1111-4222-8333-444455556666'
SECRETO = 'SECRETO-NO-DEBE-SALIR-7431'

DOCKER_POSTIZO = r'''#!/usr/bin/env bash
dir="$FAKE_DOCKER_DIR"
n=$(cat "$dir/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$dir/count"
printf '%s\n' "$@" > "$dir/argv.$n"
cat > "$dir/stdin.$n"
if [ -f "$dir/out.$n" ]; then cat "$dir/out.$n"; fi
rc=0; if [ -f "$dir/rc.$n" ]; then rc=$(cat "$dir/rc.$n"); fi
exit "$rc"
'''

SALIDA_UNA = (
    '@@CONVERSACIONES\n'
    f'{UUID}|Cliente Uno|584141234567|open|2026-10-20 10:00|\n'
)

SALIDA_DOS = (
    '@@CONVERSACIONES\n'
    f'{UUID}|Cliente Uno|584141234567|open|2026-10-20 10:00|\n'
    'f8b70000-aaaa-4bbb-8ccc-ddddeeeeffff|Cliente Dos|584149999999|closed|2026-09-01 08:00|\n'
)

SALIDA_DETALLE = (
    '@@MESSAGES\n'
    '10-20 10:00|customer|Hola, quiero enviar 18200\n'
    '10-20 10:02|agent|[media]\n'
    '@@OPERATIONS\n'
    'f8b7779c|remesa|cuban_card|completed|18200.00 GYD|70.00 USD|||10-20 10:05|10-20 11:00\n'
    'aaaa1111|recarga|||completed|6200.00 GYD|||10-20 10:06|\n'
    '@@BENEFICIARIOS\n'
    'f8b7779c|cuban_card|Ana Tester|1111|584121112222|||vigente|notes_parse\n'
    '@@AUDIT\n'
    '10-20 10:07|human_correction|amount|claude-code:owner-request|4111 1111 1111 1111\n'
    '@@DEPOSITS\n'
    'TX123|6200.00|GYD|consumido|aaaa1111\n'
    '@@CALCULATOR\n'
    'f8b7779c|2026-10-20|CLASICA|completed|18200.00|GYD|1000.00|||\n'
    '@@TOOLS\n'
    '10-20 10:01|buscar_contacto|marcado\n'
)


def cargar_modulo():
    spec = importlib.util.spec_from_file_location('conversacion', SCRIPT)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


class ClasificarTests(unittest.TestCase):
    def setUp(self):
        self.m = cargar_modulo()

    def test_prefijo_hex_es_id(self):
        self.assertEqual(self.m.clasificar('f8b7779c'), ('id', 'f8b7779c'))

    def test_digitos_son_telefono(self):
        self.assertEqual(self.m.clasificar('584141234567'), ('telefono', '584141234567'))

    def test_letras_son_nombre(self):
        self.assertEqual(self.m.clasificar('María Pérez'), ('nombre', 'María Pérez'))

    def test_consulta_insegura_se_rechaza(self):
        for q in ["'; drop table x;--", '12345', 'ab', 'a%', 'x_y', '', '$(rm -rf)',
                  'f8b77 79c', '+584141234567', '1234 5678']:
            with self.subTest(q=q):
                with self.assertRaises(self.m.Error):
                    self.m.clasificar(q)


class EnmascararTests(unittest.TestCase):
    def setUp(self):
        self.m = cargar_modulo()

    def test_tarjeta_se_enmascara(self):
        self.assertEqual(self.m.enmascarar('4111 1111 1111 1111'), '[num]')
        self.assertEqual(self.m.enmascarar('4111111111111111'), '[num]')

    def test_uuid_y_telefono_no_se_enmascaran(self):
        for valor in ['c851bfdd-1a2b-3456-7890-123456789abc', '584141234567', 'f8b7779c']:
            with self.subTest(valor=valor):
                self.assertEqual(self.m.enmascarar(valor), valor)


class EntornoTests(unittest.TestCase):
    """Cada prueba corre el script como CLI con HOME y repo temporales."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.home = base / 'home'
        (self.home / '.config' / 'wacrm').mkdir(parents=True)
        self.env_prod = self.home / '.config' / 'wacrm' / 'prod-db.env'
        self.env_prod.write_text(
            '# test\n'
            f'PROD_DATABASE_URL=postgres://lectura:{SECRETO}@db.invalid/prod\n')
        self.raiz = base / 'repo'
        self.raiz.mkdir()
        (self.raiz / '.env.staging').write_text(
            f'CRM_STAGING_DATABASE_URL=postgres://lectura:{SECRETO}@db.invalid/stg\n')
        self.bin = base / 'bin'
        self.bin.mkdir()
        docker = self.bin / 'docker'
        docker.write_text(DOCKER_POSTIZO)
        docker.chmod(0o755)
        self.log = base / 'log'
        self.log.mkdir()
        self.vacio = base / 'vacio'
        self.vacio.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def preparar_salidas(self, *salidas, rc=None):
        for i, salida in enumerate(salidas, start=1):
            (self.log / f'out.{i}').write_text(salida)
            if rc is not None:
                (self.log / f'rc.{i}').write_text(str(rc))

    def correr(self, *args, sin_docker=False):
        env = {
            'PATH': str(self.vacio) if sin_docker else f'{self.bin}{os.pathsep}{os.environ.get("PATH", "")}',
            'HOME': str(self.home),
            'WACRM_RAIZ': str(self.raiz),
            'FAKE_DOCKER_DIR': str(self.log),
            'LANG': 'C.UTF-8',
        }
        r = subprocess.run([sys.executable, str(SCRIPT), *args], env=env,
                           capture_output=True, text=True, timeout=60)
        return r

    def llamadas(self):
        p = self.log / 'count'
        return int(p.read_text()) if p.exists() else 0

    def argv(self, n):
        return (self.log / f'argv.{n}').read_text().splitlines()

    def stdin(self, n):
        return (self.log / f'stdin.{n}').read_text()


class CLITests(EntornoTests):
    def test_prod_usa_env_file_de_produccion_sin_url_en_argv(self):
        self.preparar_salidas(SALIDA_UNA, SALIDA_DETALLE)
        r = self.correr('f8b7779c')
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.argv(1)
        self.assertIn('--env-file', argv)
        self.assertEqual(argv[argv.index('--env-file') + 1], str(self.env_prod))
        for n in (1, 2):
            self.assertNotIn(SECRETO, ' '.join(self.argv(n)))
            self.assertNotIn('postgres://', ' '.join(self.argv(n)))
        self.assertIn('"$PROD_DATABASE_URL"', ' '.join(argv))
        self.assertNotIn(SECRETO, r.stdout + r.stderr)

    def test_staging_usa_env_de_staging(self):
        self.preparar_salidas(SALIDA_UNA, SALIDA_DETALLE)
        r = self.correr('f8b7779c', '--staging')
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.argv(1)
        self.assertEqual(argv[argv.index('--env-file') + 1], str(self.raiz / '.env.staging'))
        self.assertIn('"$CRM_STAGING_DATABASE_URL"', ' '.join(argv))
        self.assertNotIn(SECRETO, ' '.join(argv))

    def test_varias_coincidencias_listan_y_no_consultan_detalle(self):
        self.preparar_salidas(SALIDA_DOS)
        r = self.correr('Cliente')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.llamadas(), 1)
        self.assertIn('--elegir', r.stdout)
        self.assertIn('f8b77', r.stdout)
        self.assertIn('f8b70000', r.stdout)

    def test_elegir_consulta_detalle_con_id_completo(self):
        self.preparar_salidas(SALIDA_DOS, SALIDA_DETALLE)
        r = self.correr('Cliente', '--elegir', '1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.llamadas(), 2)
        self.assertIn(f"\\set cid '{UUID}'", self.stdin(2))
        self.assertIn('CALCULATOR', r.stdout)

    def test_elegir_fuera_de_rango_falla(self):
        self.preparar_salidas(SALIDA_DOS)
        r = self.correr('Cliente', '--elegir', '5')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.llamadas(), 1)

    def test_tarjeta_enmascarada_y_auditoria_sin_numero_completo(self):
        self.preparar_salidas(SALIDA_UNA, SALIDA_DETALLE)
        r = self.correr('f8b7779c')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('1111', r.stdout)
        self.assertNotIn('4111', r.stdout)
        self.assertNotIn('4111 1111 1111 1111', r.stdout)
        self.assertIn('[num]', self.stdin(2))

    def test_consulta_insegura_no_llama_a_docker(self):
        r = self.correr("'; drop table x;--")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.llamadas(), 0)

    def test_falta_env_file_falla_con_mensaje(self):
        self.env_prod.unlink()
        r = self.correr('f8b7779c')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('prod-db.env', r.stderr)
        self.assertEqual(self.llamadas(), 0)

    def test_falta_docker_falla_con_mensaje(self):
        r = self.correr('f8b7779c', sin_docker=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('docker', r.stderr)

    def test_sin_coincidencias_no_hay_detalle(self):
        self.preparar_salidas('@@CONVERSACIONES\n')
        r = self.correr('f8b7779c')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.llamadas(), 1)

    def test_consulta_pasa_solo_por_stdin_y_mensajes_por_defecto(self):
        self.preparar_salidas(SALIDA_UNA, SALIDA_DETALLE)
        self.correr('f8b7779c')
        s = self.stdin(1)
        self.assertIn("\\set q 'f8b7779c'", s)
        self.assertNotIn("f8b7779c'", ' '.join(self.argv(1)))
        self.assertIn('\\set n 40', self.stdin(2))

    def test_mensajes_media_cuando_texto_nulo(self):
        self.preparar_salidas(SALIDA_UNA, SALIDA_DETALLE)
        self.correr('f8b7779c')
        self.assertIn("'[media]'", self.stdin(2))
        self.assertIn('left(', self.stdin(2))


if __name__ == '__main__':
    unittest.main()
