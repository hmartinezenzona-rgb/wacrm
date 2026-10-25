// ============================================================
// Shrink an attached image before it travels to Hermes.
//
// A photo straight from a phone is several megabytes; the chat route caps the
// body and DeepSeek caps each image at 32 MiB. Downscaling to a readable size
// keeps the request small, keeps the reply fast and loses nothing the admin
// would need to check a voucher.
//
// `scaledSize` stays pure so the maths is tested without a canvas.
// ============================================================

export const MAX_SIDE = 1600;
export const JPEG_QUALITY = 0.82;
const RETRY_QUALITY = 0.6;

export interface ScaledSize {
  width: number;
  height: number;
}

/** Fit inside a square of `maxSide`, never enlarge, never return 0. */
export function scaledSize(width: number, height: number, maxSide = MAX_SIDE): ScaledSize {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return { width: 0, height: 0 };
  }
  const largest = Math.max(width, height);
  if (largest <= maxSide) {
    return { width: Math.round(width), height: Math.round(height) };
  }
  const ratio = maxSide / largest;
  return {
    width: Math.max(1, Math.round(width * ratio)),
    height: Math.max(1, Math.round(height * ratio)),
  };
}

export class ImageTooLargeError extends Error {}

/**
 * Read a picked file into a JPEG data URL no wider than `maxSide`.
 * Throws `ImageTooLargeError` when the browser still cannot get under the cap.
 */
export async function compressImage(file: File, maxBytes: number): Promise<string> {
  if (!file.type.startsWith('image/')) {
    throw new ImageTooLargeError('El archivo no es una imagen.');
  }
  const bitmap = await createImageBitmap(file);
  try {
    const { width, height } = scaledSize(bitmap.width, bitmap.height);
    if (!width || !height) throw new ImageTooLargeError('La imagen está vacía.');
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new ImageTooLargeError('El navegador no pudo procesar la imagen.');
    // JPEG has no alpha; paint white so transparent PNGs do not turn black.
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, width, height);
    ctx.drawImage(bitmap, 0, 0, width, height);

    for (const quality of [JPEG_QUALITY, RETRY_QUALITY]) {
      const url = canvas.toDataURL('image/jpeg', quality);
      if (dataUrlBytes(url) <= maxBytes) return url;
    }
    throw new ImageTooLargeError('La imagen sigue siendo demasiado grande. Prueba con una captura.');
  } finally {
    bitmap.close();
  }
}

function dataUrlBytes(url: string): number {
  const base64 = url.slice(url.indexOf(',') + 1);
  return Math.floor((base64.length * 3) / 4);
}
