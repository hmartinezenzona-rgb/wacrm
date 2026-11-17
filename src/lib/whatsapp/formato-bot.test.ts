import { describe, expect, it } from 'vitest'
import { aFormatoWhatsapp, fronteraSalida, partirEnBurbujas, prepararRespuestaBot } from './formato-bot'

describe('aFormatoWhatsapp', () => {
  it('pasa Markdown a formato de WhatsApp', () => {
    const t = aFormatoWhatsapp('## Resumen\n**Folio:** AP-1\n* Válvulas\n* Conexiones\n[Sitio](https://ap.mx)\n\n\n\nFin')
    expect(t).toBe('*Resumen*\n*Folio:* AP-1\n- Válvulas\n- Conexiones\nSitio: https://ap.mx\n\nFin')
  })
  it('deja intacto el formato propio de WhatsApp', () => {
    expect(aFormatoWhatsapp('Su folio es *AP-DE6SOC*.\n- 10 · válvula')).toBe('Su folio es *AP-DE6SOC*.\n- 10 · válvula')
  })
})

describe('partirEnBurbujas', () => {
  it('la pregunta final va en el mismo mensaje, separada por una línea en blanco', () => {
    const t = '*Su solicitud:*\n- 10 pzas · válvula\n\nA nombre de *Humberto*, para el *sábado*.\n\n¿Está correcto?'
    expect(partirEnBurbujas(t)).toEqual([t])
  })
  it('parte por párrafos y nunca más de 3', () => {
    const p = 'x'.repeat(600)
    const b = partirEnBurbujas([p, p, p, p, p].join('\n\n'))
    expect(b).toHaveLength(3)
    expect(b.join('\n\n')).toBe([p, p, p, p, p].join('\n\n'))
  })
  it('no separa una lista de su encabezado', () => {
    const b = partirEnBurbujas(`${'a'.repeat(690)}\n\n*Su solicitud:*\n\n- 10 · válvula\n- 5 · codo`)
    expect(b[b.length - 1]).toContain('*Su solicitud:*')
    expect(b[b.length - 1]).toContain('- 5 · codo')
  })
})

describe('prepararRespuestaBot', () => {
  it('no manda botones: quita la marca y deja la pregunta', () => {
    expect(prepararRespuestaBot('Listo.\n\n¿Necesita algo más?\n[botones: Agregar | Es todo]')).toEqual([
      { tipo: 'texto', texto: 'Listo.\n\n¿Necesita algo más?' },
    ])
    expect(prepararRespuestaBot('Resumen.\n\n¿Está correcto?').every((p) => p.tipo === 'texto')).toBe(true)
  })
  it('texto normal va como texto', () => {
    expect(prepararRespuestaBot('Con gusto. ¿Qué medida necesita?')).toEqual([
      { tipo: 'texto', texto: 'Con gusto. ¿Qué medida necesita?' },
    ])
  })
})

describe('fronteraSalida', () => {
  it('quita razonamiento y nombres de herramientas', () => {
    expect(fronteraSalida('El cliente quiere válvulas, debo preguntar la medida.\nVoy a llamar a ver_catalogo.\n\n¿Qué medida necesita?')).toBe('¿Qué medida necesita?')
  })
  it('quita precios y avisa una vez antes de la pregunta', () => {
    expect(fronteraSalida('Manejamos Swagelok. Cada válvula cuesta $1,250 más IVA.\n\n¿Cuántas necesita?')).toBe(
      'Manejamos Swagelok.\n\nEl precio se lo enviamos en la cotización.\n\n¿Cuántas necesita?',
    )
    expect(fronteraSalida('Sale en 300 pesos.')).toBe('El precio se lo enviamos en la cotización.')
  })
  it('no toca medidas, cantidades ni folios', () => {
    const t = 'Le resumo lo que registro:\n\n- 10 válvulas de bola de 1/2" inoxidable 3000 psi\n\nSu folio es *AP-X1Y2Z3*.'
    expect(fronteraSalida(t)).toBe(t)
  })
})
