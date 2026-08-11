// Normaliza el FORMATO de la respuesta antes de enviarla. Determinista,
// sin IA, sin coste. No reescribe: solo mete saltos de parrafo.
//
// PRINCIPIO INNEGOCIABLE: solo INSERTA saltos, nunca reconstruye.
// Una version anterior troceaba en frases y volvia a unir, y se COMIA
// contenido cuando algo no casaba. En mensajes con cifras de dinero eso
// es inaceptable. Al final hay una comprobacion: si el texto sin
// espacios no es identico al original, se devuelve el ORIGINAL.
function normalizar(txt) {
  if (!txt) return txt;
  if (txt.includes('\n\n')) return txt;   // ya trae PARRAFOS de verdad: no se toca
  // Corto: normalmente un parrafo esta bien. PERO si acaba en PREGUNTA y
  // delante hay una idea completa, la pregunta merece su propia linea aunque
  // el mensaje sea corto: "Por 30,000 GYD llegan 90,000 CUP a Cuba. ¿Desde
  // donde va a depositar?" son DOS cosas, y pegadas no se leen.
  const mPreg = txt.match(/^([\s\S]*?)\s+(?:¿[^?]+\?|(?:How|What|When|Where|Which|Can|Could|Would|Do|Did|Are|Is)\b[^?]*\?)\s*$/);
  const preguntaConIdeaDelante = !!(mPreg && mPreg[1].trim().length >= 40);
  if (txt.length < 110 && !preguntaConIdeaDelante) return txt;

  let t = txt.trim();

  // 1) El saludo de apertura, solo. (es + en)
  t = t.replace(/^((?:Buenos días|Buenas tardes|Buenas noches|Good morning|Good afternoon|Good evening)[^.]*\.)\s+/i, '$1\n\n');

  // 2) La pregunta final, sola.
  t = t.replace(/\s+(¿[^?]+\?)\s*$/, '\n\n$1');
  t = t.replace(/(?<=[.!?])\s+((?:How|What|When|Where|Which|Can|Could|Would|Do|Did|Are|Is)\b[^?]*\?)\s*$/, '\n\n$1');

  // 3) Un corte mas en el cuerpo largo. El punto NO puede ir entre
  //    digitos: sin este guardia, "2.8 CUP" se parte y el cliente lee
  //    otra cifra.
  const bloques = t.split('\n\n');
  if (bloques.length < 3) {
    const i = bloques.length - 1 >= 1 ? bloques.length - 1 : 0;
    const cuerpo = bloques[i];
    if (cuerpo && cuerpo.length > 130) {
      const mitad = Math.floor(cuerpo.length / 2);
      const re = /\.\s+(?=[A-ZÁÉÍÓÚ¿])/g;
      let m, corte = -1;
      while ((m = re.exec(cuerpo)) !== null) {
        if (m.index >= mitad) { corte = m.index + 1; break; }
        corte = m.index + 1;
      }
      if (corte > 0 && corte < cuerpo.length - 20) {
        bloques[i] = cuerpo.slice(0, corte).trim() + '\n\n' + cuerpo.slice(corte).trim();
      }
    }
  }
  t = bloques.join('\n\n');

  // 4) RED DE SEGURIDAD. Mejor mal formateado que incompleto.
  const sinEspacios = s => s.replace(/\s+/g, ' ').trim();
  if (sinEspacios(t) !== sinEspacios(txt)) return txt;

  return t.trim();
}

// QUITA EL RAZONAMIENTO QUE SE COLA COMO TEXTO HACIA EL CLIENTE.
//
// El 10-ago cuatro respuestas salieron con el razonamiento del modelo delante:
//   "El cliente dijo \"Clasica tropical\" pero no eligio claramente entre las
//    dos. Necesito saber cual de las dos quiere. Le pregunto.
//
//    Perfecto. ¿En cual de las dos: Clasica o Tropical?"
// Tres clientes distintos, todas el mismo dia. Dos de ellas hablaban de la via
// de deposito y repetian casi literal la frase del prompt ("no se asume nunca"
// -> "No debo asumir"): el propio prompt le da el material para deliberar.
//
// Esto es un CONTROL, no una instruccion: pase lo que pase en el modelo, el
// razonamiento no sale. Es la leccion del 10-ago repetida tres veces — si algo
// tiene que pasar si o si, no puede depender de que el modelo obedezca.
//
// CONSERVADOR A PROPOSITO:
//   - solo mira el PRIMER parrafo,
//   - solo corta si queda respuesta de verdad detras,
//   - nunca deja el mensaje vacio.
// Si el mensaje entero fuera razonamiento sin respuesta, NO se toca: preferimos
// un mensaje raro a un silencio, que es lo que dejo a clientes esperando 90 h.
// Verificado sobre los 275 mensajes que ha enviado el bot: caza los 4 filtrados
// y ni uno mas.
function quitarRazonamiento(txt) {
  if (typeof txt !== 'string' || !txt) { return txt; }
  const partes = txt.split(/\n\s*\n/);
  if (partes.length < 2) { return txt; }
  const primera = partes[0].trim();
  const esRazonamiento = /^(el (cliente|usuario)\b|parece que el (cliente|usuario)\b|(no debo|no puedo) (asumir|dar por)|voy a (preguntar|pedir)\b|debo (preguntar|pedir|confirmar)\b)/i.test(primera);
  if (!esRazonamiento) { return txt; }
  const resto = partes.slice(1).join('\n\n').trim();
  if (!resto) { return txt; }
  return resto;
}

// Mantiene la forma {output} para que `Responder por WaCRM` siga usando
// $json.output sin cambiar su expresion.
return $input.all().map(item => {
  try {
    const original = item.json.output;
    if (typeof original !== 'string') { return item; }
    const limpio = quitarRazonamiento(original);
    const quitado = limpio !== original;
    return { json: { ...item.json, output: normalizar(limpio),
                     razonamiento_quitado: quitado } };
  } catch (e) {
    return item;   // ante la duda, el mensaje original
  }
});