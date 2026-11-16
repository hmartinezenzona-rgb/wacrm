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
  it('no parte textos cortos', () => {
    expect(partirEnBurbujas('Hola\n\nQué tal')).toHaveLength(1)
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
  it('pone botones cuando pide confirmar', () => {
    const p = prepararRespuestaBot('*Su solicitud:*\n- 10 · válvula\n\n¿Está correcto?')
    expect(p).toHaveLength(1)
    expect(p[0].tipo).toBe('botones')
    if (p[0].tipo === 'botones') {
      expect(p[0].payload.buttons.map((b) => b.title)).toEqual(['Sí, es correcto', 'Corregir algo'])
    }
  })
  it('respeta botones pedidos por el bot', () => {
    const p = prepararRespuestaBot('¿Qué prefiere?\n[botones: Cotizar | Hablar con ventas]')
    expect(p[0].tipo).toBe('botones')
    if (p[0].tipo === 'botones') {
      expect(p[0].payload.body).toBe('¿Qué prefiere?')
      expect(p[0].payload.buttons.map((b) => b.title)).toEqual(['Cotizar', 'Hablar con ventas'])
    }
  })
  it('texto normal va como texto', () => {
    expect(prepararRespuestaBot('Con gusto. ¿Qué medida necesita?')).toEqual([
      { tipo: 'texto', texto: 'Con gusto. ¿Qué medida necesita?' },
    ])
  })
})
