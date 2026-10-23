# Preguntas para Osmany: envíos a México

Abierto desde el 2026-10-04; actualizado el 2026-10-23. En staging México ya es una operación propia (con sus
destinatarios CLABE o retiro sin tarjeta); estas respuestas cierran lo que falta antes de producción.

## Lo que ya sabemos

- Tarifa al cliente: 260 GYD por dólar, mínimo 13,000 GYD (50 USD), sin máximo (los montos grandes se avisan antes).
- Al negocio le cuesta lo mismo que los demás envíos en USD (dueño, 2026-10-22).
- Se deposita por MMG y sale el mismo día, a los pocos minutos de verificar el pago.
- La persona en México recibe pesos mexicanos al cambio del día, que pone el operador a mano.
- Cuenta bancaria: CLABE (18 dígitos), banco (por ejemplo Mercado Pago, Banco Azteca) y titular. Un mismo envío puede
  ir a varias CLABE.
- Retiro sin tarjeta en Coppel o BBVA, solo múltiplos de 100.
- La cuenta Albo era una prueba: se quita.
- Retiro sin tarjeta BBVA (fuentes públicas de BBVA México, 2026-10-23): quien envía genera en la app BBVA un código
  de 12 dígitos (o un QR) con el monto, y se lo pasa a quien retira; quien retira solo necesita ese código para
  sacar el dinero en un cajero BBVA (o un QR en Oxxo). El banco no pide el teléfono de quien retira. Los límites
  varían según la fuente (cajero BBVA: hasta 12,000 MXN al día; Oxxo: 100 a 3,000 MXN por retiro).
- Retiro sin tarjeta Coppel: no hay información pública clara de cómo funciona.

## Preguntas

**Tasa y montos**
1. ¿De dónde sale el cambio de USD a pesos mexicanos de cada día (qué banco, app o casa de cambio)? ¿Lo fijas tú o
   lo mira el operador en el momento?
2. ¿Al cliente se le dice cuántos pesos van a llegar antes de pagar, o solo los dólares? Si se le dice, ¿quién lo
   calcula: el bot con la tasa del día que pongas en el panel, o el operador?
3. Cuando el cliente pide "X dólares a México", ¿llegan exactamente esos dólares convertidos a pesos, o se redondea
   (por ejemplo, a múltiplos de 100 pesos en el retiro sin tarjeta)? ¿Qué pasa con la diferencia del redondeo?

**Retiro sin tarjeta**
4. ¿Desde qué app y cuenta se generan los retiros (BBVA del negocio, Coppel del negocio)? ¿Los dos funcionan igual con
   un código?
5. ¿A quién se le manda el código: al cliente por este chat, o directo a quien retira? Si es directo, ¿hace falta su
   teléfono? (El banco no lo pide.)
6. ¿Hace falta el nombre de quien retira, o basta con el código?
7. ¿Hay un máximo por retiro o por día que debamos avisar al cliente (por los límites del cajero o de la app)?
8. En Coppel: ¿cómo funciona exactamente y qué dato necesita quien retira?

**Cuenta bancaria**
9. ¿Basta con CLABE, banco y titular? ¿Hace falta algo más (teléfono, número de tarjeta en vez de CLABE)?
10. ¿Se puede enviar a cualquier banco mexicano o hay alguno que no funcione?

**Cierre y aviso al cliente**
11. ¿Cuándo se da por terminado un envío a México y qué se le manda al cliente (captura de la transferencia, el código
    del retiro)?
12. ¿Cuánto suele tardar en verse el dinero en la cuenta o estar disponible el retiro?
