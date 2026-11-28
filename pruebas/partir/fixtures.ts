// Real bot replies (anonymised: names, cards, phones, accounts and links are fake) used as fixtures
// for the splitter. `grupos` is the expected outcome as groups of block indexes: the blocks are the
// pieces of the reply separated by blank lines, numbered from 0. One group = one WhatsApp message.
export type Fixture = {
  nombre: string;
  texto: string;
  grupos: number[][];
};

export const FIXTURES: Fixture[] = [
  {
    nombre: 'ejemplo 1: envio a tres destinos con encargados ausentes',
    texto: `Le entendí todo, queda así:
*Efectivo en Cuba para Persona A:* Calle 1 #100 entre Calle 2 y Calle 3, Rpto Ejemplo, teléfono *53000001*. Un compañero coordina zona y horario con usted.
*5,000 GYD a tarjeta en Cuba:* tarjeta *9200 0000 0000 0001* y celular *52000002*.
*150 USD a México:* CLABE *722000000000000001*, Mercado Pago, a nombre de Persona B.

Ahora mismo los encargados no están disponibles porque tuvieron un asunto personal; regresan mañana a las 9:00 am. Por aquí le seguimos atendiendo y lo suyo se hace en cuanto ellos regresen.
Una vez realizada su remesa le notificaremos por acá.`,
    grupos: [[0], [1]],
  },
  {
    nombre: 'ejemplo 2: primera pregunta por Zelle (5 ideas, tope de 4)',
    texto: `Buenos días, le atiende el asistente virtual de *Remesas Ya*.

Sí, trabajamos Zelle. La tarifa va por tramos: *260 GYD* por dólar desde 50 hasta 999 USD, *250 GYD* desde 1,000 USD y *245 GYD* desde 2,000 USD.

El depósito lo puede hacer a:
*Titular:* [TITULAR]
*Cuenta MMG:* [CUENTA MMG]

Tenemos un grupo de WhatsApp de *Remesas Ya* donde compartimos tasas, promociones y avisos al instante. Únete aquí:
[ENLACE AL GRUPO]

¿Cuánto desea enviar?`,
    grupos: [[0, 1], [2], [3], [4]],
  },
  {
    nombre: 'ejemplo 3: Zelle con deposito de mas, fuera de horario',
    texto: `Buenos días, le atiende el asistente virtual de *Remesas Ya*.
Estamos fuera de horario, pero por aquí le atendemos igual.
Anotado, la cuenta Zelle queda así:

*Nombre:* Persona C
*Celular:* 4320000003

Recibimos su depósito de *26,000 GYD*, y vemos que fue más de lo que habíamos hablado, ningún problema: un compañero le confirma cómo se resuelve.
Su envío de *100 USD* se hace en cuanto abramos, a partir de las 9:00am hora de Guyana.`,
    grupos: [[0, 1], [2]],
  },
  {
    nombre: 'ejemplo 4: cuenta Zelle recibida y deposito verificado al cierre',
    texto: `Buenas tardes, le atiende el asistente virtual de *Remesas Ya*.

Anotado. La cuenta Zelle queda así:

*Nombre:* Persona D
*Celular:* 3050000004

Su depósito de *18,200 GYD* ha sido verificado.
Hoy ya vamos cerrando, así que su remesa de *70 USD* por Zelle se hace mañana a primera hora, a partir de las 9:00am, y una vez hecha le notificamos por acá.`,
    grupos: [[0], [1, 2], [3]],
  },
  {
    nombre: 'ejemplo 5: recalcular un envio a varios destinos',
    texto: `Sí, le entendí: *10,000 GYD* para Persona E van aparte y *5,000 GYD* sí van a una tarjeta en Cuba.
Le saco la cuenta otra vez:
*150 USD a México:* *39,000 GYD*
*100 USD en efectivo en Cuba:* *29,000 GYD*
*5,000 GYD a tarjeta en Cuba:* llegan *15,000 CUP*
Total a depositar: *73,000 GYD*.
Lo de los *1,200* de mensajería no lo tengo en la tarifa, eso me lo confirma un compañero.

¿Me pasa los datos de quien recibe?`,
    grupos: [[0], [1]],
  },
  {
    nombre: 'ejemplo 6: cuenta para depositar y promocion de recargas',
    texto: `Buenos días, le atiende el asistente virtual de *Remesas Ya*.

Estamos fuera de horario, pero por aquí le atendemos igual.

La cuenta para depositar es la misma de siempre:

*Titular:* [TITULAR]
*MMG:* [CUENTA MMG]

Y sí, las recargas se mantienen: *600 CUP* por *6,200 GYD*, con la promo de Etecsa que multiplica lo recargado x5, válida hasta el 24/10.

¿Quiere hacer una recarga?`,
    grupos: [[0, 1], [2, 3], [4], [5]],
  },
  {
    nombre: 'ejemplo 7: el cliente manda la cuenta Zelle',
    texto: `Buenos días, le atiende el asistente virtual de *Remesas Ya*.

Para poner *200 USD* por Zelle necesita depositar *52,000 GYD*.

Anotado. La cuenta Zelle queda así:

*Nombre:* Persona F
*Celular:* 832 000 0007

¿Desde dónde va a depositar, desde la app o con un agente?`,
    grupos: [[0], [1], [2, 3], [4]],
  },
  {
    nombre: 'ejemplo 8: dos tarjetas y un Zelle, deposito verificado al cierre',
    texto: `Buenas tardes, le atiende el asistente virtual de *Remesas Ya*.

Su depósito de *27,200 GYD* ha sido verificado.

Anotado: *5,000* a cada tarjeta, o sea *15,000 CUP* a cada una, y *66 USD* al Zelle.

Como ya vamos cerrando, su envío sale mañana sábado a primera hora, a partir de las 9:00am.

¿Me pasa el celular que va con cada tarjeta?`,
    grupos: [[0, 1], [2], [3], [4]],
  },
  {
    nombre: 'ejemplo 9: deposito distinto de lo hablado, al cierre',
    texto: `Buenas tardes, le atiende el asistente virtual de *Remesas Ya*.
Su depósito de *5,000 GYD* ha sido verificado.
Vemos que fue distinto a los *7,000* que hablamos, ningún problema, se le transfiere el equivalente.
Hoy ya vamos cerrando, así que su remesa se hace mañana miércoles a primera hora, a partir de las 9:00am, y una vez hecha le notificamos por acá.

¿Me pasa los datos de quien recibe?`,
    grupos: [[0], [1]],
  },
  {
    nombre:
      'ejemplo 10: reparto de un deposito grande (cierre corto se une al anterior)',
    texto: `Perfecto, todo queda así con su depósito de *285,000 GYD*:

*Zelle:* 800 USD a Persona G y 200 USD a Empresa H. Los 100 USD quedan pendientes de esa cuenta que me pasa más tarde.
*Pesos cubanos:* 30,000 CUP a la tarjeta *9200000000000010*, celular *59000010*.

Las transferencias salen enseguida.`,
    grupos: [[0, 1, 2]],
  },
  {
    nombre: 'fase 2: un dato por linea, deposito verificado y pregunta final',
    texto: `Anotado, los datos de quien recibe quedan así:

*Nombre:* Persona J
*Tarjeta:* *9200 0000 0000 0002*
*Celular:* 52000003

Su depósito de *12,000 GYD* ha sido verificado.

¿Todo correcto?`,
    grupos: [[0, 1], [2], [3]],
  },
  {
    nombre: 'fase 2: "Su remesa queda asi:" con lista, cuenta y pregunta',
    texto: `Su remesa queda así:

- *150 USD* a México: *39,000 GYD*
- *100 USD* en efectivo en Cuba: *29,000 GYD*
- *5,000 GYD* a tarjeta en Cuba: *15,000 CUP*

Total a depositar: *73,000 GYD*.

La cuenta para depositar es:
*Titular:* [TITULAR]
*MMG:* [CUENTA MMG]

¿Desde dónde va a depositar?`,
    grupos: [[0, 1], [2, 3], [4]],
  },
  {
    nombre: 'fase 2: cuenta de deposito en su propio mensaje',
    texto: `Perfecto, ya tengo todo para su envío de *70 USD*.

Para depositar los *18,200 GYD* use esta cuenta:

*Titular:* [TITULAR]
*Cuenta MMG:* [CUENTA MMG]

Cuando lo haga, mándeme la captura por aquí.

¿Lo hace hoy?`,
    grupos: [[0], [1, 2], [3], [4]],
  },
  {
    nombre: 'fase 2: dos listas seguidas se quedan juntas con su introduccion',
    texto: `Estos son los datos que tengo hasta ahora:

- *Nombre:* Persona K
- *Celular:* 52000004

- *Nombre:* Persona L
- *Celular:* 52000005

Falta la tarjeta de Persona L. ¿Me la pasa?`,
    grupos: [[0, 1, 2], [3]],
  },
  {
    nombre: 'fase 2: lista numerada con "1." y "2)"',
    texto: `Para el envío necesito estos datos del beneficiario:

1. Nombre completo
2) Número de tarjeta
3. Celular

Cuando los tenga, se los paso a un compañero para que coordine.

¿Me los pasa?`,
    grupos: [[0, 1], [2], [3]],
  },
  {
    nombre: 'fase 2: vinetas con asterisco y punto medio',
    texto: `Tengo anotado lo siguiente de su envío:

* *150 USD* a México
• *100 USD* en efectivo en Cuba
- *5,000 GYD* a tarjeta en Cuba

Todo sale en cuanto el depósito esté verificado por el equipo.

¿Quiere cambiar algo?`,
    grupos: [[0, 1], [2], [3]],
  },
];

/** Splits a reply in blocks (blank lines), the same way the node does. */
export function bloques(texto: string): string[] {
  return texto
    .replace(/\r\n/g, '\n')
    .trim()
    .split(/\n[ \t]*(?:\n[ \t]*)+/)
    .map((b) => b.trim())
    .filter((b) => b !== '');
}

/** Expected parts of a fixture: its groups of blocks joined with blank lines. */
export function partesEsperadas(f: Fixture): string[] {
  const b = bloques(f.texto);
  return f.grupos.map((g) => g.map((i) => b[i]).join('\n\n'));
}
