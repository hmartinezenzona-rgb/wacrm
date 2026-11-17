import { describe, expect, it } from 'vitest'
import { aFormatoWhatsapp, partirEnBurbujas, prepararRespuestaBot } from './formato-bot'

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
  it('un solo párrafo va en una burbuja', () => {
    expect(partirEnBurbujas('Con gusto. ¿Qué medida necesita?')).toHaveLength(1)
  })
  it('la pregunta final va sola en su burbuja', () => {
    expect(partirEnBurbujas('Manejamos estas marcas:\n- ASCO\n- Parker\n\n¿Le interesa alguna?')).toEqual([
      'Manejamos estas marcas:\n- ASCO\n- Parker',
      '¿Le interesa alguna?',
    ])
    expect(partirEnBurbujas('Listo, su folio es *AP-1*.\n\nLa gerente le enviará la cotización. ¿Desea agregar algo más?')).toEqual([
      'Listo, su folio es *AP-1*.',
      'La gerente le enviará la cotización. ¿Desea agregar algo más?',
    ])
  })
  it('el resumen queda junto y la pregunta aparte', () => {
    expect(partirEnBurbujas('*Su solicitud:*\n- 10 pzas · válvula\n\n*A nombre de:* Humberto\n*Para:* sábado\n\n¿Está correcto?')).toEqual([
      '*Su solicitud:*\n- 10 pzas · válvula\n\n*A nombre de:* Humberto\n*Para:* sábado',
      '¿Está correcto?',
    ])
  })
  it('parte por párrafos y nunca más de 3', () => {
    const p = 'x'.repeat(300)
    const b = partirEnBurbujas([p, p, p, p, p].join('\n\n'))
    expect(b).toHaveLength(3)
    expect(b.join('\n\n')).toBe([p, p, p, p, p].join('\n\n'))
  })
  it('no separa una lista de su encabezado', () => {
    const b = partirEnBurbujas(`${'a'.repeat(370)}\n\n*Su solicitud:*\n\n- 10 · válvula\n- 5 · codo`)
    expect(b[b.length - 1]).toContain('*Su solicitud:*')
    expect(b[b.length - 1]).toContain('- 5 · codo')
  })
})

describe('prepararRespuestaBot', () => {
  it('no manda botones: quita la marca y deja la pregunta', () => {
    expect(prepararRespuestaBot('Listo.\n\n¿Necesita algo más?\n[botones: Agregar | Es todo]')).toEqual([
      { tipo: 'texto', texto: 'Listo.' },
      { tipo: 'texto', texto: '¿Necesita algo más?' },
    ])
    expect(prepararRespuestaBot('Resumen.\n\n¿Está correcto?').every((p) => p.tipo === 'texto')).toBe(true)
  })
  it('texto normal va como texto', () => {
    expect(prepararRespuestaBot('Con gusto. ¿Qué medida necesita?')).toEqual([
      { tipo: 'texto', texto: 'Con gusto. ¿Qué medida necesita?' },
    ])
  })
})
