// =====================================================================
//  Webhook Affiliate Consulting (Base44) → CRM Sirius
//
//  Étape 1 : on écoute. Chaque événement (inscription, achat, annulation)
//  est rangé tel quel dans affiliate_events, pour voir ce qui arrive
//  vraiment. Rien d'autre n'est modifié.
//
//  Deux protections : l'adresse porte une clé (?cle=…), et chaque envoi
//  est signé par Affiliate Consulting (X-AC-Signature : t=…,v1=…,
//  HMAC-SHA256 du secret sur « t.corps brut », en hexadécimal). Un envoi
//  de plus de 5 minutes est refusé : on ne peut pas en rejouer un vieux.
//  X-AC-Delivery identifie l'envoi : une nouvelle tentative n'est gardée
//  qu'une fois.
//
//  Secrets (Supabase → Edge Functions → Secrets) :
//    AFFILIATE_WEBHOOK_KEY      la clé de l'adresse
//    AFFILIATE_SIGNING_SECRET   le secret de signature (whsec_…), tel quel
//  SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par Supabase.
//
//  Déploiement : « Verify JWT » désactivé.
// =====================================================================

// Un espace ou un retour à la ligne collé avec le secret fausserait tout.
const CLE = (Deno.env.get('AFFILIATE_WEBHOOK_KEY') ?? '').trim()
const SECRET_SIGNATURE = (Deno.env.get('AFFILIATE_SIGNING_SECRET') ?? '').trim()
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

const reponse = (statut: number, corps: unknown) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { 'Content-Type': 'application/json' } })

function egal(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

// Renvoie le verdict, et de quoi comprendre un refus sans jamais exposer le
// secret : sa longueur, son préfixe, l'âge de l'envoi, le début des deux
// signatures.
async function verifierSignature(entete: string, corps: string) {
  const parts: Record<string, string> = {}
  for (const p of entete.split(',')) {
    const i = p.indexOf('=')
    if (i > 0) parts[p.slice(0, i).trim()] = p.slice(i + 1).trim()
  }
  const t = Number(parts.t), v1 = (parts.v1 ?? '').toLowerCase()
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(SECRET_SIGNATURE), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${parts.t ?? ''}.${corps}`)))
  const attendu = Array.from(sig).map((b) => b.toString(16).padStart(2, '0')).join('')
  const age = t ? Math.round(Date.now() / 1000 - t) : null
  const ok = !!t && !!v1 && age !== null && Math.abs(age) <= 300 && egal(attendu, v1)
  return {
    ok,
    diag: {
      entete_present: !!entete, age_secondes: age,
      v1_debut: v1.slice(0, 8), attendu_debut: attendu.slice(0, 8),
      secret_longueur: SECRET_SIGNATURE.length, secret_whsec: SECRET_SIGNATURE.startsWith('whsec_'),
      secret_espaces: SECRET_SIGNATURE !== SECRET_SIGNATURE.trim(),
    },
  }
}

// Le type d'événement, là où les envois le mettent d'habitude.
function typeDe(p: Record<string, unknown>): string | null {
  for (const k of ['event', 'type', 'event_type', 'eventType', 'action', 'name']) {
    const v = p[k]
    if (typeof v === 'string' && v) return v.slice(0, 80)
  }
  return null
}

Deno.serve(async (req) => {
  const url = new URL(req.url)
  if (!CLE || !egal(url.searchParams.get('cle') ?? '', CLE)) return reponse(401, { erreur: 'clé invalide' })

  const brut = req.method === 'GET' ? '' : await req.text()
  if (brut.length > 100_000) return reponse(413, { erreur: 'trop gros' })

  // Le secret de signature posé : un envoi sans signature valide est refusé.
  let signatureOk: boolean | null = null
  let refus: Record<string, unknown> | null = null
  if (SECRET_SIGNATURE) {
    const v = await verifierSignature(req.headers.get('x-ac-signature') ?? '', brut)
    signatureOk = v.ok
    if (!v.ok) refus = v.diag
  }
  let payload: Record<string, unknown> = {}
  if (brut) {
    try { payload = JSON.parse(brut) } catch {
      payload = Object.fromEntries(new URLSearchParams(brut))
    }
  }
  // Une « Postback URL » envoie tout dans l'adresse.
  for (const [k, v] of url.searchParams) if (k !== 'cle' && !(k in payload)) payload[k] = v

  // On garde les en-têtes pour repérer une éventuelle signature, sans les secrets.
  // Un envoi refusé (bonne clé, mauvaise signature) est gardé à part pour
  // comprendre pourquoi : il ne compte pour rien, et Affiliate Consulting
  // le retentera.
  const entetes: Record<string, string> = {}
  for (const [k, v] of req.headers) {
    if (!/^(authorization|cookie|apikey)$/i.test(k)) entetes[k] = v.slice(0, 500)
  }

  const r = await fetch(`${SUPABASE_URL}/rest/v1/affiliate_events?on_conflict=delivery`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      // Un envoi déjà reçu (même X-AC-Delivery) est ignoré sans erreur.
      Prefer: 'return=minimal,resolution=ignore-duplicates',
    },
    body: JSON.stringify({
      methode: req.method,
      type: refus ? 'refusé' : req.headers.get('x-ac-event') || typeDe(payload),
      delivery: refus ? null : req.headers.get('x-ac-delivery') || null,
      signature_ok: signatureOk,
      payload: refus ? { diagnostic: refus, payload } : payload, brut: brut || null, entetes,
    }),
  })
  // Une erreur de la base : 500, et l'envoi sera retenté.
  if (!r.ok) {
    console.error('Enregistrement impossible', r.status, (await r.text()).slice(0, 300))
    return reponse(500, { erreur: 'enregistrement impossible' })
  }
  if (refus) return reponse(401, { erreur: 'signature invalide' })
  return reponse(200, { ok: true })
})
