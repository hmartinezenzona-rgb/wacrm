# T3 — casos expuestos, agrupados por la decision que necesitan

Generado desde `casos/casos-conversaciones.json` el 2026-10-18.

Criterio: solo fuerza comportamiento viejo lo que una expectativa marca como **obligatorio**.
Un caso cuyas `obligatorias` estan vacias deja libre al bot y no necesita decision, aunque viva en
una familia expuesta. Por eso la lista es mucho mas corta que los 45 iniciales.

La batería entera nace en agosto de 2026 y 58 de 60 casos se arbitraron el 12-ago, antes del efectivo
(28-sep), saldo movil (6-oct), los tramos de Zelle (5-oct), el cambio de servicio (8-oct) y las
herramientas de datos a medias (1-oct). Las CIFRAS siguen bien: `cerebro_tasa_zelle` da 260 para
50, 115, 500 y 510 USD igual.

## DECISION 1 — cotizar sin via dicha  (2 casos)

El caso EXIGE un calculador y el cliente NO dijo moneda ni via. En agosto el bot cotizaba CUP;
hoy la regla 113 dice no cotizar y preguntar. **?Cual vale hoy?** Si es "preguntar", estos se
corrigen como los de Z. Si es "cotizar", lo que hay que quitar es la regla 113.

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `reg-26966-calculo-con-herramienta` | calculo-con-herramienta | 510 | calcular_usd | 132600, 510 |
| `reg-27123-calculo-con-herramienta` | calculo-con-herramienta | 500 | calcular_usd | 130000, 500 |

## DECISION 2 — registro de beneficiario  (12 casos)

Expectativas congeladas antes de las herramientas de datos a medias (179/180, 1-oct), que guardan
el dato en cuanto llega aunque falte el otro. **?Deben exigir registro PARCIAL desde el primer
turno, o el todo-o-nada de agosto?** El gate 79 ya midio que el parcial funciona.

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `reg-27115-beneficiario-zelle` | beneficiario-zelle | 7863469349 / Yudelqui Pupo | registrar_beneficiario_zelle | 7863469349 |
| `reg-27129-beneficiario-zelle` | beneficiario-zelle | Raquel Machado Arias / +1 (737) 484-7752 | registrar_beneficiario_zelle | 484, 737, 7752 |
| `reg-27172-beneficiario-zelle` | beneficiario-zelle | Diane jaime | registrar_beneficiario_zelle | — |
| `reg-27414-beneficiario-zelle` | beneficiario-zelle | la cuenta zelle es +1 (317) 903-7295 a nombre de Yoandri Montero | registrar_beneficiario_zelle | 317, 7295, 903 |
| `reg-27500-beneficiario-zelle` | beneficiario-zelle | (el cliente envio solo imagenes, sin texto) | registrar_beneficiario_zelle | 554, 6932, 786 |
| `reg-27506-beneficiario-zelle` | beneficiario-zelle | +1 (317) 903-7295 | registrar_beneficiario_zelle | 30000 |
| `reg-27598-beneficiario-zelle` | beneficiario-zelle | Jose Luis Rodríguez Velázquez +17867071855 | registrar_beneficiario_zelle | 17867071855 |
| `reg-29890-multi-herramienta` | multi-herramienta | correcto | registrar_beneficiario_zelle, registrar_reparto_multiple | 51292073, 9238129972337028 |
| `reg-29922-beneficiario-zelle` | beneficiario-zelle | siderponce65@gmail.com /  /  / Sider Ponce de León /  /  / Hasta 199 | registrar_beneficiario_zelle | — |
| `reg-30478-reparto-multiple` | reparto-multiple | Si / Muvhas gracias | registrar_reparto_multiple | 55773738, 9238129976250508 |
| `reg-32635-calculo-desde-contexto` | calculo-desde-contexto | (561) 720-3103 /  / La Llave Jewerly | registrar_beneficiario_zelle | — |
| `zelle-alta-beneficiario-desde-datos-detectados` | beneficiario-zelle | *ZELLE 🇺🇸* /  / Nombre: PenCargo Trading Company /  / 786 407-3217 | registrar_beneficiario_zelle | — |

## DECISION 3 — precios y condiciones  (7 casos)

Precios de agosto. Ya detectado: el `resumen` de visa dice 4,000 GYD y sus `hechos` y el prompt
dicen 5,000. **?Confirmas el precio de hoy de cada servicio que salga aqui?**

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `reg-24612-servicios` | servicios | [Nota de voz del cliente]: Bueno, bendiciones Osmany. Me enteré  | consultar_servicio | 500, 5200, 600, 6200 |
| `reg-25497-servicios` | servicios | [Nota de voz del cliente]: Hola, buenas noches. Deseo saber si l | consultar_servicio | 600, 6200 |
| `reg-25500-promo` | promo | [Nota de voz del cliente]: Pudiera hacer el depósito mañana? / [No | — | — |
| `reg-25614-servicios` | servicios | Hola, quiero mandar un combo de comida para Las Tunas, que preci | consultar_servicio | 25000 |
| `reg-25682-servicios` | servicios | cuanto cuesta la extension de visa y que necesito? | consultar_servicio | 20000, 4000 |
| `reg-29665-servicios` | servicios | En cuanto ustedes venden el Zelle , es decir el cambio en guyane | consultar_servicio | 260 |
| `servicio-traduccion-pregunta-de-detalle` | servicios | Para traducir, una hoja cuenta como una cara o como las dos cara | consultar_servicio | — |

## YA CORREGIDOS (2026-10-18)  (3 casos)

Derivados de tu propia regla 113 y de tus ejemplos (lineas 351/353/355); el esperado anterior
quedo en `esperado_pre_regla_113`. **Si la DECISION 1 es "cotizar CUP", hay que revertirlos.**

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `reg-27065-multi-herramienta` | multi-herramienta | a como esta el cambio? cuanto llega si envio 30 mil? | consultar_tasas | — |
| `reg-28021-multi-herramienta` | multi-herramienta | A cómo esta el cambio? Cuánto llega si envío 30 mil? | consultar_tasas | — |
| `reg-30178-calculo-con-herramienta` | calculo-con-herramienta | Voy a tranferir 30mil gy a las 5 pm | — | — |

## SIN DECISION — cotizar con via dicha  (10 casos)

El cliente SI dijo la via o la moneda y el caso exige el calculador correspondiente. Nada que
decidir: solo confirmar que siguen verdes al medir el candidato.

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `doble-pregunta-tasa-y-calculo-inverso` | calculo | Y cuanto tengo que depositar para que le lleguen 100 mil CUP? di | calcular_inverso | 35720, 2.8, 100000 |
| `reg-24999-multi-herramienta` | multi-herramienta | Buenas, y para mandar dinero a Mexico? cuanto llega con 20 mil? | calcular_usd_desde_gyd, consultar_servicio | 13000, 20000, 260 |
| `reg-26685-calculo-con-herramienta` | calculo-con-herramienta | Para comprale 120 Zelle hoy | calcular_usd | 120, 31200 |
| `reg-26704-calculo-con-herramienta` | calculo-con-herramienta | Para comprar 100 zelle cuanto sería en guyanes y a qué cuenta ma | calcular_usd | 100, 26000 |
| `reg-26908-calculo-con-herramienta` | calculo-con-herramienta | Ok le voy a comprar 130 zelle | calcular_usd | 130, 33800 |
| `reg-27486-calculo-con-herramienta` | calculo-con-herramienta | Amigo deposite en su cuenta para 50 zelle | calcular_usd | 13000 |
| `reg-29547-calculo-con-herramienta` | calculo-con-herramienta | [Nota de voz del cliente]: Amigo, buenos días. Déjame hacerle un | calcular_usd | 200, 52000 |
| `reg-29548-calculo-con-herramienta` | calculo-con-herramienta | Es decir en total tengo q enviar 220 zelle | calcular_usd | 220, 57200 |
| `reg-31265-calculo-con-herramienta` | calculo-con-herramienta | Hola, y 315 dolares por zelle cuanto seria? | calcular_usd | 315, 81900 |
| `reg-31333-calculo-con-herramienta` | calculo-con-herramienta | Y para mandar 100 dolares por zelle cuanto seria? | calcular_usd | 100, 26000 |

## SIN DECISION — no exigen herramienta  (11 casos)

No exigen ningun calculador ni registro: sus `obligatorias` estan vacias, asi que el bot puede
cotizar o callar y pasan igual. Estan en familias expuestas pero no fuerzan comportamiento viejo.

| caso | familia | mensaje del cliente | obligatorias | cifras |
|---|---|---|---|---|
| `reg-25003-multi-herramienta` | multi-herramienta | Otra cosa, cuanto me cuesta traducir 3 hojas? y hay recarga hoy? | consultar_servicio | 4000 |
| `reg-26689-calculo-con-herramienta` | calculo-con-herramienta | Le preguntaba que si 100 se mantienen 26 mil guyanés | — | — |
| `reg-26787-calculo-desde-contexto` | calculo-desde-contexto | Verificaste que llegaron los 39,000? | — | — |
| `reg-26862-calculo-con-herramienta` | calculo-con-herramienta | [Nota de voz del cliente]: Buenos días, Dios te bendiga. Osmany, | — | — |
| `reg-32395-saldo-envio` | saldo-envio | Ya le pase los datos del zelle | — | — |
| `reg-32399-saldo-envio` | saldo-envio | (el cliente envio solo imagenes, sin texto) | — | — |
| `reg-32454-calculo-desde-contexto` | calculo-desde-contexto | Buenas, cuanto llegan por 30000 guyaneses? | — | 30000 |
| `reg-32666-calculo-desde-contexto` | calculo-desde-contexto | Dile al socio de la agencia que te mande el nombre del zelle des | — | — |
| `reg-32820-saldo-envio` | saldo-envio | [Nota de voz del cliente]: Sí, primero le tengo que pasar el din | — | — |
| `reg-32899-calculo-desde-contexto` | calculo-desde-contexto | 9224 0699 9110 4171 / Este es la tarjeta / 56508454 | — | 56508454, 9224069991104171 |
| `reg-32930-calculo-desde-contexto` | calculo-desde-contexto | [Nota de voz del cliente]: Voy a ir a una agencia de MMG. Cuando | — | — |
