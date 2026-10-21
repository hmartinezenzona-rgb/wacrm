import { uploadResumableMedia } from '@/lib/whatsapp/meta-api'
import type { TemplatePayload } from '@/lib/whatsapp/template-validators'
import { parseChatMediaPath } from '@/lib/storage/chat-media'
import { downloadChatMedia } from '@/lib/storage/chat-media-server'

/**
 * Meta requires an `example.header_handle` (from the Resumable Upload
 * API) to create/edit a template with an IMAGE header — a plain public
 * URL is not accepted at creation time. This helper turns the template's
 * `header_media_url` (whether the user uploaded a file or pasted a link)
 * into a handle and writes it onto the payload, so both the upload path
 * and the legacy URL path actually succeed.
 *
 * No-op unless the header is an image that has a URL but no handle yet.
 * Image-only for now (the #230 scope); video/document handles can follow
 * the same shape.
 */

// Meta's image-header sample limits.
const IMAGE_MAX_BYTES = 5 * 1024 * 1024
const ALLOWED_IMAGE_TYPES = ['image/jpeg', 'image/png']

export async function ensureImageHeaderHandle(
  payload: TemplatePayload,
  accessToken: string,
): Promise<void> {
  if (payload.header_type !== 'image') return
  if (payload.header_handle) return // already have one
  if (!payload.header_media_url) return // validator already requires url-or-handle

  const appId = process.env.META_APP_ID
  if (!appId) {
    throw new Error(
      'Image-header templates need META_APP_ID set (used for Meta’s Resumable Upload). Add it to your environment, or remove the image header.',
    )
  }

  // Fetch the sample image bytes. Our own chat-media objects are read
  // with the service role (the bucket may be private); a manually-pasted
  // public link is fetched as before.
  let contentType: string
  let bytes: Uint8Array
  const chatMediaPath = parseChatMediaPath(payload.header_media_url)
  if (chatMediaPath) {
    const media = await downloadChatMedia(chatMediaPath)
    if (!media) {
      throw new Error('Could not read the header image from storage.')
    }
    contentType = media.contentType.split(';')[0].trim().toLowerCase()
    bytes = new Uint8Array(media.bytes)
  } else {
    let res: Response
    try {
      res = await fetch(payload.header_media_url)
    } catch {
      throw new Error('Could not fetch the header image URL. Make sure it is publicly reachable.')
    }
    if (!res.ok) {
      throw new Error(`Header image URL returned ${res.status}. It must be publicly reachable.`)
    }
    contentType = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase()
    bytes = new Uint8Array(await res.arrayBuffer())
  }

  if (contentType && !ALLOWED_IMAGE_TYPES.includes(contentType)) {
    throw new Error(`Header image must be JPEG or PNG (got ${contentType}).`)
  }
  if (bytes.byteLength === 0) {
    throw new Error('Header image is empty.')
  }
  if (bytes.byteLength > IMAGE_MAX_BYTES) {
    throw new Error(
      `Header image is ${(bytes.byteLength / 1024 / 1024).toFixed(1)} MB — Meta's limit is 5 MB.`,
    )
  }

  const mimeType = ALLOWED_IMAGE_TYPES.includes(contentType) ? contentType : 'image/jpeg'
  const fileName = mimeType === 'image/png' ? 'header.png' : 'header.jpg'

  const { handle } = await uploadResumableMedia({
    appId,
    accessToken,
    fileName,
    mimeType,
    bytes,
  })
  payload.header_handle = handle
}
