# Dos caídas silenciosas el 10 de agosto

Las dos ocurrieron el mismo día, con causas distintas, y comparten lo peor:
**nadie se enteró por una alarma**. Las dos se encontraron mirando otra cosa.

---

## 1. La ingesta de correos de MMG, 4 horas parada

### Qué pasó

El **último correo de MMG entró en el libro a las 14:02 UTC**. Se descubrió a
las **17:44**, revisando por qué no se había verificado el depósito de un
cliente. Casi cuatro horas, en plena tarde de lunes.

Consecuencia directa: **desde las 14:46 ningún depósito se verificó solo**.
Nueve seguidos, todos con la referencia ausente del libro. Osmany se pasó la
tarde verificando a mano sin saber por qué, y tres clientes con **194.200 GYD**
quedaron esperando.

### La causa

**La credencial de Gmail había caducado.** Las dos, de hecho:

```
Osmany Pozo (depositos x agente)  -> paro a las 14:02
Osmany Pozo (Cuenta mmg)          -> paro a las 00:23
```

Las dos devolvían:

> *«Access could not be refreshed because the connected account has revoked
> access, the refresh token expired, or the account password or permissions
> changed. Open the credential and reconnect it to continue.»*

### Por qué no saltó ninguna alarma — lo importante

**El Gmail Trigger de n8n no genera ejecuciones cuando el sondeo falla.** El
workflow sigue *activo* y *sin errores*: simplemente deja de encontrar correos.
Desde fuera es idéntico a «hoy no ha depositado nadie».

- No hay ejecución con error → el manejador de errores no dispara.
- No hay evento atascado → la vigilancia diaria no lo ve.
- La conciliación sigue en orden → tampoco.

**Ninguna de las redes que tenemos cubre esto.**

### Cómo se diagnosticó

Un **workflow de diagnóstico aparte**, de solo lectura, que usa la misma
credencial para listar los correos del remitente. Devolvió el error de OAuth en
un segundo. Reutilizable: es la forma de distinguir «no llegan correos» de «no
los puedo leer».

### Cómo se arregló

Humberto reconectó las dos credenciales desde la interfaz de n8n. **Eso no se
puede hacer por API**: el OAuth de Google exige navegador y la cuenta.

> Al reconectar dio **«The OAuth callback state is invalid»**. Se resolvió
> cerrando todas las pestañas de n8n, entrando de nuevo y completando el flujo
> sin demorarse, en el mismo perfil del navegador. El `state` viaja en una
> cookie de sesión y caduca.

**La ingesta se recuperó sola**: a las 18:12 hizo una pasada y recogió los 12
correos atrasados de golpe. No hizo falta la carga histórica
(`1k3IGZszdiMcmzDo`), que sigue ahí para cuando sea necesaria.

### Lo que falta, y es lo que evitaría la próxima

**Un vigilante de la ingesta.** Algo tan simple como: si no entra ningún
depósito en N horas de horario de negocio, avisar en el CRM. Hoy no existe.

```sql
-- lo que habria dado la alarma a las 15:00
SELECT to_char(max(recibido_en),'HH24:MI') AS ultimo,
       round(EXTRACT(epoch FROM (now()-max(recibido_en)))/60) AS hace_minutos
  FROM depositos_mmg;
```

---

## 2. Yo rompí el Cerebro 27 minutos

### Qué pasó

Al desplegar el cambio de «no preguntar la vía si ya depositó», la consulta de
`Contexto conversacion` tenía un **error de sintaxis**. Por ese nodo pasa
**todo** mensaje, así que el Cerebro dejó de responder entre las **17:46 y las
18:13**.

| | |
|---|---|
| Duración | 27 minutos |
| Clientes afectados | 2 |
| **Depósitos perdidos** | **ninguno** |
| Dinero afectado | ninguno |

El fallo ocurría **después** del registro del depósito y del cruce, así que los
comprobantes se guardaron bien. Las dos remesas se completaron. Los 8 eventos
atascados se marcaron como completados en vez de reproducirlos: las dos
conversaciones ya estaban cerradas y el bot habría contestado a un *«Gracias»*
de media hora antes.

### La causa, sin adornos

**Validé con `PREPARE` una versión recortada de la consulta y desplegué otra.**
Escribí a mano una variante más corta para el `PREPARE`, dio verde, y subí la
larga. La larga llevaba un salto de línea escapado dentro de una expresión
regular que se deformó al pasar por JSON.

Es **exactamente** la lección del 9-ago que está escrita en este mismo repo:
*«si se monta la validación, se ejecuta entera»*. La tenía delante y la repetí.

### Cómo se detectó

**Por casualidad.** Comprobando el estado de la base tras arreglar lo de la
ingesta, aparecieron 8 `session_events` en `permanent_error`. Nadie avisó:
las ejecuciones fallaban, pero el aviso al admin va por WhatsApp y **la ventana
de 24 h estaba cerrada** — el problema conocido de siempre.

### Qué se hizo distinto al rehacerlo

1. **Fuera las expresiones regulares.** `split_part` y `chr(10)`: cero barras
   invertidas que se puedan deformar.
2. **Un banco de pruebas aparte en n8n** con un nodo Postgres cargado con la
   consulta **copiada del propio JSON por programa**, sin teclear nada.
3. Antes de desplegar, se compara byte a byte que la consulta a desplegar es la
   **misma** que validó el banco.

**Y el banco encontró dos cosas que `PREPARE` no habría encontrado nunca:**

- Faltaba **una coma** entre `tiene_beneficiario` y la columna nueva. La
  construcción del parche se comió el separador.
- Un **control**: se cargó primero la consulta de producción en el banco para
  comprobar que el banco estaba bien montado antes de creerse un fallo suyo.

> **La lección operativa:** `PREPARE` valida SQL, pero el nodo de n8n hace cosas
> con el texto antes de enviarlo. La única prueba fiable de una consulta de un
> workflow es **ejecutarla dentro de n8n, con el texto exacto**.

---

## Cómo se prueba de verdad un cambio del `Decisor`

Salió de esta misma sesión, y de una pregunta de Humberto: *«¿lo probaste con
una simulación de la conversación real en la que falló?»*. La respuesta era
**no**.

Se había comprobado que el cambio no rompía nada, mandando un mensaje a la
conversación de pruebas. Pero esa conversación **no tenía depósito**, así que
`via_deposito_ya_usada` salía vacío y **la rama nueva no llegó a ejecutarse
nunca**. Verde, y sin haber probado lo que importaba.

**El `Decisor` no se puede montar aislado en n8n** —depende de una docena de
nodos previos—, así que la prueba buena es otra: **reconstruir el estado en la
conversación de pruebas y reproducir el mensaje que falló**.

```sql
-- 1. dejar la conversacion de pruebas en el mismo estado que la que fallo
INSERT INTO deals (..., conversation_id, notes)
VALUES (..., '<conv de pruebas>',
        E'DEPOSITO: 39,000 GYD - EXITOSA\nVia: Agente MMG;\n...');
```

```bash
# 2. mandar POR EL WEBHOOK FIRMADO el mensaje exacto que provoco el fallo
#    (aqui: dar la cuenta Zelle DESPUES de haber depositado)
```

Y después mirar **las tres cosas**, no solo la respuesta:

1. que el contexto trae el dato nuevo (`via_deposito_ya_usada = 'Agente MMG'`),
2. que el `Decisor` emitió la nota nueva,
3. **y qué le llegó al cliente**.

Resultado de esa prueba:

| | |
|---|---|
| Antes | *«Anotado. La cuenta Zelle queda así… **¿Desde dónde va a depositar, desde la app o con un agente?**»* |
| Después | *«Anotado. La cuenta Zelle queda así… **Su depósito ya lo tenemos registrado, apenas lo verifiquemos le hacemos el envío.**»* |

> **La regla:** una prueba que no ejercita la rama nueva no es una prueba, es una
> comprobación de que no se rompió nada. Son cosas distintas y hay que decirlo
> por separado. Y al terminar, borrar el deal, la operación, el beneficiario y
> la memoria que dejó la prueba.

---

## Lo que enseñan las dos juntas

**Un sistema que no da señal cuando se cae no está vigilado, está en silencio.**
Las dos caídas fueron invisibles para todas las redes que existen:

| Red | ¿Habría avisado? |
|---|---|
| Manejador de errores del Cerebro | no (el trigger no genera ejecución; y el aviso va por WhatsApp) |
| Vigilancia diaria | no (mira eventos atascados, no ausencia de correos) |
| Conciliación de operaciones | no |
| Vigilante de chats atascados | tarde, y por otro motivo |

Y las dos se encontraron **mirando otra cosa**. Eso no es un método: es suerte.
