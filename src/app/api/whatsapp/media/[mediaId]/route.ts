import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { getMediaUrl, downloadMedia } from '@/lib/whatsapp/meta-api'
import { decrypt } from '@/lib/whatsapp/encryption'

// Meta media ids are numeric; anything else cannot be one of ours.
const MEDIA_ID_RE = /^[A-Za-z0-9]{1,64}$/

/**
 * True when a message of one of the account's conversations references
 * this Meta media id: either the legacy proxy URL
 * (`/api/whatsapp/media/<id>`) or a stored object named `...-wa-<id>.<ext>`.
 * Without this any logged-in user could pull any media their WhatsApp
 * business token can see, whichever account it belongs to.
 */
async function accountOwnsMedia(
  supabase: Awaited<ReturnType<typeof createClient>>,
  accountId: string,
  mediaId: string,
): Promise<boolean> {
  const base = () =>
    supabase
      .from('messages')
      .select('id, conversations!inner(account_id)')
      .eq('conversations.account_id', accountId)
      .limit(1)

  const byProxyUrl = await base().eq('media_url', `/api/whatsapp/media/${mediaId}`)
  if (byProxyUrl.data?.length) return true

  const byFileName = await base().like('media_url', `%wa-${mediaId}.%`)
  return !!byFileName.data?.length
}

export async function GET(
  request: Request,
  { params }: { params: Promise<{ mediaId: string }> }
) {
  try {
    const { mediaId } = await params

    if (!mediaId) {
      return NextResponse.json(
        { error: 'Media ID is required' },
        { status: 400 }
      )
    }

    const supabase = await createClient()

    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser()

    if (authError || !user) {
      return NextResponse.json(
        { error: 'Unauthorized' },
        { status: 401 }
      )
    }

    // Resolve the caller's account_id — whatsapp_config is one-per-
    // account post-multi-user, so a teammate fetching media for a
    // conversation in the shared inbox needs the account's config,
    // not their personal (non-existent) row.
    const { data: profile } = await supabase
      .from('profiles')
      .select('account_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const accountId = profile?.account_id as string | undefined
    if (!accountId) {
      return NextResponse.json(
        { error: 'Your profile is not linked to an account.' },
        { status: 403 },
      )
    }

    if (!MEDIA_ID_RE.test(mediaId) || !(await accountOwnsMedia(supabase, accountId, mediaId))) {
      return NextResponse.json({ error: 'Media not found' }, { status: 404 })
    }

    // Fetch and decrypt WhatsApp config
    const { data: config, error: configError } = await supabase
      .from('whatsapp_config')
      .select('*')
      .eq('account_id', accountId)
      .single()

    if (configError || !config) {
      return NextResponse.json(
        { error: 'WhatsApp not configured' },
        { status: 400 }
      )
    }

    const accessToken = decrypt(config.access_token)

    // Get the download URL from Meta
    const mediaInfo = await getMediaUrl({ mediaId, accessToken })

    // Download the binary data
    const { buffer, contentType } = await downloadMedia({
      downloadUrl: mediaInfo.url,
      accessToken,
    })

    return new Response(new Uint8Array(buffer), {
      status: 200,
      headers: {
        'Content-Type': contentType || mediaInfo.mimeType || 'application/octet-stream',
        'Cache-Control': 'private, max-age=3600',
      },
    })
  } catch (error) {
    console.error('Error in WhatsApp media GET:', error)
    return NextResponse.json(
      { error: 'Failed to fetch media' },
      { status: 500 }
    )
  }
}
