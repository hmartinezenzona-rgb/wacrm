# Contexto para otras IA: cómo funciona el negocio y qué queremos resolver

Este documento describe el negocio, el sistema actual y los problemas abiertos, para que otra IA pueda
revisar el diseño y aportar puntos de vista. **No incluye datos personales de clientes**: nombres,
teléfonos, tarjetas y textos de conversaciones están omitidos o anonimizados. Las cifras y los ids de
operación son reales pero sin identificar a nadie.

## 1. El negocio

Remesas Ya es una casa de remesas en Guyana que envía dinero a Cuba. El cliente deposita guyaneses
(GYD) en Guyana y el negocio entrega el equivalente en Cuba por una de varias vías:

| Vía | Qué recibe el cliente | Moneda |
|---|---|---|
| Tarjeta CUP (`cuban_card`) | Saldo en una tarjeta cubana | CUP |
| Zelle | Dólares a una cuenta Zelle en EE. UU. | USD |
| Clásica | Dólares a una tarjeta Clásica (FINCIMEX) | USD |
| Tropical | Dólares a una tarjeta Tropical (BANDEC) | USD |
| Efectivo USD | Dólares físicos en Cuba (con dirección y carnet) | USD |
| Recarga | Saldo móvil cubano (solo con promoción) | CUP |
| Combo | Comida a domicilio en Cuba | — |
| Visa | Extensión de visa | — |
| México | Pesos mexicanos por CLABE o retiro sin tarjeta | MXN |
| MLC / USDT | Se atiende con una persona; no se cotiza automáticamente | — |

- **Depósitos**: por el agente MMG (Osmany Pozo, cuenta 6762167) o por la app (Osmany Services, pay
  merchant 6990225). El cliente manda el comprobante por WhatsApp.
- **Tasas vigentes (ejemplo, cambian a diario)**: 1 GYD = 3 CUP; USD por Zelle por tramos (260 / 250 /
  245 GYD por USD según el monto); Clásica, Tropical, México y USDT a 260; efectivo USD a 290.
- **Mínimos (ejemplo)**: CUP 5,000 GYD; Zelle 13,000 GYD (50 USD); Clásica/Tropical 20 USD (5,200
  GYD); recarga 5,200 o 6,200 GYD según la promoción; efectivo 100 USD.
- **Horario**: lunes a sábado 9:00–17:00 hora de Guyana; domingo cerrado; hay días cerrados y modo
  ausencia del equipo.
- **Roles**: el dueño define reglas; Osmany atiende y opera; un asistente interno (Hermes) consulta
  datos y prepara informes; el desarrollo lo lleva Claude Code.

## 2. El sistema, pieza por pieza

**Entrada de mensajes**

- WhatsApp Cloud API (Meta) entrega al webhook de WaCRM (aplicación Next.js sobre Supabase/Postgres).
- WaCRM guarda el mensaje y dispara un webhook a n8n.
- n8n ejecuta el workflow **Cerebro** (producción, 131 nodos). Hay un staging que comparte el token de
  WhatsApp de producción: **nunca se ejecuta**; solo se edita y se valida con fixtures.
- Una **ventana de agrupado** de 20 segundos junta varios mensajes seguidos del cliente en un lote.
  Un candado por conversación evita que dos turnos procesen el mismo lote.

**Lectura de datos**

- Los comprobantes, tarjetas, teléfonos y carnets se leen con visión (cuatro lecturas rotadas) y una
  ficha de formatos. Una función determinista verifica cada dato: Luhn y prefijo de tarjeta, formato de
  referencia MMG, longitud de teléfono/carnet, importes.
- El comprobante se cruza contra el libro de depósitos de MMG (`depositos_mmg`, alimentado por correo).
  Si la referencia existe, el depósito se registra y se verifica.
- Los audios se transcriben y se tratan como texto.

**El agente**

- Un nodo **Decisor** (código JavaScript, versionado y con tests) construye el `[CONTEXTO DEL SISTEMA]`
  que recibe el modelo: tasas, estado del envío, notas de servicio, historial, horario, idioma,
  instrucciones obligatorias de herramientas.
- El agente usa un modelo DeepSeek y **21 herramientas** que llaman funciones de Postgres. Las
  principales: `consultar_tasas`, `calcular_envio`, `calcular_usd`, `calcular_inverso`,
  `gestionar_beneficiario`, `registrar_beneficiario_zelle`, `registrar_reparto_multiple`,
  `marcar_destino_usd`, `declarar_servicio`, `cambiar_servicio`, `agregar_servicio`, `repartir_envio`,
  `modificar_operacion`, `registrar_numeros_recarga`, `registrar_datos_entrega_efectivo`,
  `registrar_destinatario_mexico`, `abrir_extension_visa`, `consultar_servicio`, `derivar_humano`.
- La memoria por conversación guarda 30 mensajes. El agente no ve lo que hizo una persona por el panel
  salvo que el Decisor se lo inyecte.

**Datos y estado**

- `remittance_operations`: una operación por envío. Campos clave: `service_type`
  (remesa/recarga/combo/visa/saldo), `delivery_method` (zelle/clasica/tropical/cuban_card/efectivo_usd/
  mexico), `status` (`collecting_information`, `deposit_verification`, `ready_to_transfer`, `incident`,
  `completed`, `cancelled`), `quoted_source_amount` (GYD), `quoted_destination_amount` y moneda,
  `mixed_group_id` (envío mixto), `admin_locked_fields`.
- `remittance_beneficiaries`: destinatarios, con tipo, tarjeta, teléfono, cuenta Zelle, monto y estado.
- `depositos_mmg`: el libro de depósitos verificados.
- `cerebro_objetivo_envio`: el objetivo del envío (lo que el cliente quiere enviar).
- `cerebro_servicio_declarado`: el servicio que el cliente dijo querer.
- `cerebro_reparto_planeado`: reparto planificado antes del depósito.
- `remittance_calculator_entries`: la calculadora/Finanzas; se alimenta al completar una operación.

**Funciones centrales**

- `cerebro_resolver_servicio(conv)`: devuelve un estado único del servicio (operaciones abiertas,
  depósito, servicio en curso, acciones posibles).
- `cerebro_registrar_deposito` / `cerebro_cruzar_depositos`: registran y cruzan el comprobante.
- `cerebro_guardar_beneficiario` / `cerebro_guardar_zelle`: guardan destinatarios; aceptan datos a
  medias.
- `cerebro_repartir_envio` / `_repartir_envio_core`: reparte un depósito entre varios servicios.
- `_cerebro_declarar_implicito`: declara el servicio a partir de una cotización (ver problemas).
- `crm_entregar_operacion`: el operador marca la operación como entregada, con evidencia (captura o
  sin comprobante).
- `calculator_feed_operation`: alimenta la calculadora al completar.

**Salida al cliente y al equipo**

- Un workflow **notificador** manda WhatsApp al cliente cuando el depósito se verifica y cuando la
  operación se completa. Dentro de la ventana de 24 h manda texto libre; fuera, una plantilla de Meta.
- El panel WaCRM muestra la bandeja, las operaciones, la calculadora, el inventario de tarjetas y los
  tableros. El operador completa, corrige y cierra.

## 3. El flujo de un envío, hoy

1. El cliente pide una cotización o dice cuánto quiere enviar. El bot cotiza con herramientas.
2. El cliente deposita y manda el comprobante (imagen, audio o texto).
3. La visión lee el comprobante; el sistema lo cruza con el libro de MMG. Si coincide, el depósito
   queda registrado y verificado.
4. El bot pide los datos de quien recibe (tarjeta y celular, cuenta Zelle, CLABE, etc.).
5. El bot guarda los destinatarios y confirma.
6. Si un solo depósito cubre varios servicios, el bot llama `repartir_envio` con las partes.
7. Cuando el depósito está verificado y los datos completos, la operación queda `ready_to_transfer`.
8. Un operador hace la transferencia y marca la operación como completada desde el panel, con
   evidencia.
9. La calculadora registra la operación; el notificador avisa al cliente; el operador cierra.

## 4. Los problemas que estamos teniendo

**4.1 El sistema crea servicios antes de saberlos.**

- Una **cotización** puede declarar el servicio y abrir una operación. El bot, para comparar precios,
  cotiza Zelle y Clásica; la segunda cotización creó una operación Clásica que el dueño tuvo que
  cancelar.
- El **depósito** se cuelga de una operación ya tipada por esa declaración, aunque el cliente nunca
  haya elegido la vía.
- Los **datos del beneficiario** se guardan en la operación del servicio declarado; si la tarjeta no
  era de ese servicio, queda en una operación huérfana y el reparto crea otra.

Ejemplo real (2026-10-26, anonimizado): un cliente deposita 285,000 GYD para 1,100 USD por Zelle
(800 + 200 + 100, con la cuenta de los 100 más tarde) y 10,000 GYD a una tarjeta en CUP. El bot cotizó
Zelle y Clásica; quedó una operación Clásica fantasma. La tarjeta se guardó en una operación Clásica y
el reparto creó una operación CUP aparte. El bot dijo que faltaban 10,000 GYD cuando el depósito
cubría todo. El operador corrigió a mano y canceló operaciones.

**4.2 El reparto no siempre se aplica.**

Otro caso: un depósito de 31,000 GYD se verificó; el cliente dio 100 USD por Zelle y el resto a una
tarjeta. El bot registró el Zelle y la tarjeta, pero no llamó a `repartir_envio`: la operación Zelle se
quedó con los 31,000 GYD (destino 119 USD) y la de la tarjeta sin depósito. Hubo que corregirlo a mano.
La causa: la orden de repartir solo vivía en una rama que exige un comprobante en el turno; el
objetivo se fija después, así que nadie comparaba el objetivo con el depósito.

**4.3 Se entrega con dinero sin asignar.**

En el caso de 1,100 USD, la operación Zelle se entregó con destinatarios por 800 + 200 = 1,000 USD. El
destinatario de los 100 llegó después; el bot abrió una operación nueva y el operador la canceló. El
único candado validaba que cada destinatario tuviera sus datos, no que los montos sumaran el envío.

**4.4 El bot repite y habla de más.**

Medición sobre 502 turnos en 69 conversaciones (19–25 oct): mediana de 19 palabras por mensaje, pero
se repiten la presentación (17.9 % de los turnos), el aviso de fuera de horario, el resumen completo de
la cotización y la misma pregunta final. Ya hay candidatos de prompt medidos con A/B; parte del
problema es que el Decisor ordena repetir el aviso en cada turno.

**4.5 El tipo de tarjeta no se usa como evidencia.**

El prompt de visión conoce dos prefijos: `92` (tarjetas RED, CUP) y `9760` (Clásica, USD). Faltaba
Tropical (`9240`) y había prefijos sin identificar. Un cliente dio una tarjeta `9234…` diciendo que era
Clásica; el número decía CUP (nómina BANDEC) y el sistema no lo usó para contradecirlo.

**4.6 Otros huecos**

- El aviso de "remesa completada" no decía el servicio; ahora usa el nombre (por Zelle, Clásica, etc.)
  y la ventana de 24 h exacta.
- El reenvío de mensajes por la ventana de agrupado genera turnos duplicados; se está midiendo.
- MLC no se cotiza (lo atiende una persona); el sistema no debe tratarlo como dólar.
- Operaciones ya completadas con registros incompletos se dejan como historia (decisión del dueño).

## 5. Lo que queremos lograr

**Principio central: ningún servicio sin datos; ninguna entrega sin servicio, destinatario, monto y
dinero asignado.**

- **El dinero vive en un expediente (`funding_case`), no en una operación.** Una operación representa
  un envío real, con servicio y datos del destinatario; nunca es el cajón donde espera el dinero.
- El depósito se verifica y entra al expediente **sin vía**. No se le inventa servicio.
- El servicio se define cuando llega la evidencia:
  1. **Datos**: cuenta Zelle → Zelle; tarjeta + celular → familia tarjeta (el prefijo decide CUP,
     Clásica o Tropical); CLABE + banco → México; teléfono con intención explícita → recarga.
  2. **Palabras explícitas** del cliente o herramientas de elección (`declarar_servicio`,
     `cambiar_servicio`, `agregar_servicio`).
  3. **Mínimo exacto**: si coincide con el mínimo de **un solo** servicio, el bot lo **sugiere y
     pregunta**; nunca asigna solo. Si coincide con dos (5,200 GYD es Clásica 20 USD y también
     recarga), pregunta.
- **Jerarquía de evidencia**: datos > palabra del cliente > sugerencia del mínimo.
- **Una contradicción es un conflicto, no una prioridad**: si el prefijo dice CUP y el cliente dice
  Clásica, se bloquea y se pregunta; no se cambia el servicio en silencio.
- **Reparto desde la asignación del cliente**: "100 a esta cuenta, 100 a esta otra y 5,000 GYD a esta
  tarjeta" define las partes; se registran como asignaciones (`funding_allocations`) contra el
  expediente; el resto queda sin asignar y se pregunta.
- **El dinero se conserva**: depósitos verificados = asignaciones activas + devoluciones + saldo sin
  asignar, verificado en SQL.
- **Conciliación determinista**: cada cambio de depósito, destinatario o asignación dispara una
  función SQL; el modelo no decide cuándo repartir ni calcula el reparto.
- **Nada se completa ni se entrega con dinero sin asignar** (candado de entrega por operación y por
  expediente).
- **El panel** debe permitir asignar servicio, repartir, cancelar y editar con auditoría.
- **El notificador** solo confirma el depósito mientras no haya vía.
- **Todo con staging primero, migraciones con ROLLBACK y sin bandera** (se vuelve atrás con el
  rollback), más un plan de reversión de datos porque un rollback de esquema no deshace asignaciones
  ni mensajes.

**Estado actual del plan**

- Ya aplicado en producción: gates de reparto (325, 326), nota de partes con el depósito del grupo y
  cotizaciones que no abren operaciones (327), candado de entrega Zelle (328), nombres de servicio en
  el aviso de completada.
- El diseño fue reescrito con el modelo de expediente (`funding_case` + `funding_allocations`) tras
  la revisión externa; el primer bloqueante es introducir el expediente y anclar el reparto en él.
- Pendiente: confirmar la tabla de prefijos con el operador, decidir MLC como handoff, prototipar
  **promptfoo** para la capa de modelo (no ejecuta n8n, base ni Decisor).

## 6. Lo que pedimos a la otra IA

1. Revisar el principio y la jerarquía de evidencia. ¿Hay contradicciones o ambigüedades que no hayamos
   visto?
2. Proponer el modelo de datos y el estado para un depósito sin vía que luego se asigna o se reparte
   (sin operaciones fantasma, sin perder dinero).
3. Revisar el flujo de reparto con un expediente como ancla y varios depósitos.
4. Señalar casos límite: datos en cualquier orden, datos repetidos o corregidos, depósitos múltiples,
   cancelaciones, devoluciones, concurrencia e idempotencia.
5. Opinar sobre la estrategia de pruebas: promptfoo para el modelo, aserciones SQL para la base, tests
   del Decisor y una conversación manual en staging.
6. Proponer una UX de panel para un depósito sin vía (operador).
7. Si hay una solución más simple que la propuesta, decirla.

**Restricciones**: no hay acceso a los sistemas desde fuera; no se deben inventar datos de clientes; las
cifras y los ejemplos son reales pero anonimizados.
