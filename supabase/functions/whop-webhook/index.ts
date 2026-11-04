// =====================================================================
//  Webhook Whop → CRM Sirius
//
//  Whop appelle cette fonction à chaque paiement. On vérifie que l'appel
//  vient bien de Whop (signature), puis, pour un paiement réussi, on
//  demande à la base de faire passer le lead d'« Opt-in » aux « Leads du
//  jour » (whop_paiement_recu, dans 09-optin-whop.sql).
//
//  Secrets (Supabase → Edge Functions → Secrets) :
//    WHOP_WEBHOOK_SECRET   le secret du webhook donné par Whop (ws_…)
//  SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par Supabase :
//  la clé service_role reste ici, côté serveur, jamais dans une page.
//
//  Déploiement : « Verify JWT » désactivé — Whop n'a pas de jeton
//  Supabase, c'est la signature qui fait foi.
// =====================================================================

const SECRET = Deno.env.get('WHOP_WEBHOOK_SECRET') ?? ''
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

// Whop suit le standard « Standard Webhooks » : HMAC-SHA256, en base64, de
// `id.timestamp.corps`. La doc de Whop dit d'utiliser le secret tel quel ;
// le standard, lui, décode en base64 ce qui suit le préfixe. On accepte les
// deux : un faux appel ne passe ni l'un ni l'autre.
function clesPossibles(secret: string): Uint8Array[] {
  const cles = [new TextEncoder().encode(secret)]
  const sansPrefixe = secret.replace(/^(ws|whsec)_/, '')
  try {
    cles.push(Uint8Array.from(atob(sansPrefixe), (c) => c.charCodeAt(0)))
  } catch { /* pas du base64 : la première clé suffit */ }
  return cles
}

async function hmac(cle: Uint8Array, texte: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', cle, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texte)))
  return btoa(String.fromCharCode(...sig))
}

function egal(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

async function signatureValide(req: Request, corps: string): Promise<boolean> {
  const id = req.headers.get('webhook-id') ?? ''
  const ts = req.headers.get('webhook-timestamp') ?? ''
  const entete = req.headers.get('webhook-signature') ?? ''
  if (!SECRET || !id || !ts || !entete) return false
  // Plus de 5 minutes d'écart : un vieil appel rejoué.
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false
  const recues = entete.split(' ').map((s) => s.replace(/^v1,/, ''))
  for (const cle of clesPossibles(SECRET)) {
    const attendue = await hmac(cle, `${id}.${ts}.${corps}`)
    if (recues.some((r) => egal(r, attendue))) return true
  }
  return false
}

const reponse = (statut: number, corps: unknown) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reponse(405, { erreur: 'POST seulement' })

  const corps = await req.text()
  if (!(await signatureValide(req, corps))) return reponse(401, { erreur: 'signature invalide' })

  let evt: { type?: string; data?: Record<string, unknown> }
  try { evt = JSON.parse(corps) } catch { return reponse(400, { erreur: 'JSON invalide' }) }

  // Les autres événements ne nous concernent pas : on répond 200 pour que
  // Whop ne les renvoie pas en boucle.
  if (evt.type !== 'payment.succeeded' || !evt.data) return reponse(200, { ignore: evt.type ?? null })

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/whop_paiement_recu`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
    },
    body: JSON.stringify({ p: evt.data }),
  })
  const resultat = await r.text()
  // Une erreur de la base : 500, et Whop retentera plus tard.
  if (!r.ok) return reponse(500, { erreur: resultat.slice(0, 300) })
  return reponse(200, { resultat: JSON.parse(resultat) })
})
