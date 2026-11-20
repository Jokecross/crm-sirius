// =====================================================================
//  Vente Skool → Meta (API Conversions)
//
//  Quand un sales valide une vente sur un lead Skool, la vraie valeur de
//  la vente part à Meta comme un « Purchase ». Meta voit alors ce que
//  chaque campagne rapporte vraiment, et pas seulement l'entrée à 9 $ dans
//  le groupe Skool (envoyée par le plugin Meta Pixel de Skool).
//
//  Le CRM appelle cette fonction après chaque enregistrement d'une vente.
//  Elle ne reçoit aucune donnée : elle cherche elle-même, en base, les
//  ventes Skool des 7 derniers jours pas encore envoyées (Meta refuse un
//  événement de plus de 7 jours) et les envoie. Un appel raté est donc
//  rattrapé au suivant, et une vente n'est jamais envoyée deux fois.
//
//  Un client qui monte d'abonnement (Mensuel → Annuel Builder) : seule la
//  différence part à Meta.
//
//  Secret (Supabase → Edge Functions → Secrets) : META_CAPI_TOKEN, le même
//  que pour whop-webhook. SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont
//  fournis par Supabase.
//
//  Déploiement : nom « meta-vente », « Verify JWT » activé (seul un
//  utilisateur connecté au CRM peut l'appeler).
//
//  Test : ?test=TEST12345 (le code de l'onglet « Tester les événements »
//  du gestionnaire d'événements) envoie en mode test, sans rien noter en
//  base : l'événement apparaît dans cet onglet et ne compte pas.
// =====================================================================

const META_TOKEN = Deno.env.get('META_CAPI_TOKEN') ?? ''
const META_PIXEL = '2199469941000913'   // le pixel d'Anthony, le même que la page Sirius
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const VENTES = ['monthly', 'yearly', 'yearly_builder']

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const reponse = (statut: number, corps: unknown) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { ...CORS, 'Content-Type': 'application/json' } })

const base = (chemin: string, opts: RequestInit = {}) => fetch(`${SUPABASE_URL}${chemin}`, {
  ...opts,
  headers: { apikey: SERVICE_ROLE, Authorization: `Bearer ${SERVICE_ROLE}`, 'Content-Type': 'application/json', ...(opts.headers ?? {}) },
})

async function empreinte(texte: string): Promise<string> {
  const sig = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texte))
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

// Seul un utilisateur connecté (pas la clé publique) peut déclencher l'envoi.
function connecte(req: Request): boolean {
  try {
    const jeton = (req.headers.get('Authorization') ?? '').replace(/^Bearer /, '')
    const charge = JSON.parse(atob(jeton.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')))
    return charge.role === 'authenticated'
  } catch { return false }
}

type Lead = {
  id: string; email: string | null; email_skool: string | null; phone: string | null
  first_name: string | null; last_name: string | null; status: string
  cash_collecte: number | null; closed_at: string; meta_vente_valeur: number | null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return reponse(405, { erreur: 'POST seulement' })
  if (!connecte(req)) return reponse(401, { erreur: 'connexion au CRM requise' })
  if (!META_TOKEN) return reponse(500, { erreur: 'META_CAPI_TOKEN manquant' })

  const test = (new URL(req.url).searchParams.get('test') ?? '').replace(/[^A-Za-z0-9]/g, '').slice(0, 40)
  const depuis = new Date(Date.now() - 7 * 864e5 + 3600e3).toISOString()   // marge d'une heure sous les 7 jours

  const r = await base(`/rest/v1/leads?select=id,email,email_skool,phone,first_name,last_name,status,cash_collecte,closed_at,meta_vente_valeur`
    + `&or=(offre.eq.skool,equipe.eq.skool)&status=in.(${VENTES.join(',')})&closed_at=gte.${depuis}&cash_collecte=gt.0`
    + `&order=closed_at.asc&limit=200`)
  if (!r.ok) return reponse(500, { erreur: (await r.text()).slice(0, 300) })
  const leads: Lead[] = await r.json()
  const aEnvoyer = leads.filter((l) => Number(l.cash_collecte) > Number(l.meta_vente_valeur ?? 0))
  if (!aEnvoyer.length) return reponse(200, { envoyees: 0 })

  const net = (t: unknown) => String(t ?? '').trim().toLowerCase()
  const data = []
  for (const l of aEnvoyer) {
    const valeur = Number(l.cash_collecte) - Number(l.meta_vente_valeur ?? 0)
    const emails = [...new Set([net(l.email), net(l.email_skool)].filter(Boolean))]
    const user_data: Record<string, string[]> = { external_id: [await empreinte(l.id)] }
    if (emails.length) user_data.em = await Promise.all(emails.map(empreinte))
    if (l.phone) user_data.ph = [await empreinte(String(l.phone).replace(/\D/g, ''))]
    if (l.first_name) user_data.fn = [await empreinte(net(l.first_name))]
    if (l.last_name) user_data.ln = [await empreinte(net(l.last_name))]
    data.push({
      event_name: 'Purchase',
      event_time: Math.floor(new Date(l.closed_at).getTime() / 1000),
      event_id: `vente-${l.id}-${l.cash_collecte}`,
      action_source: 'phone_call',
      user_data,
      custom_data: { value: valeur, currency: 'USD', content_name: `Abonnement ${l.status}`, content_category: 'skool' },
    })
  }

  const rep = await fetch(`https://graph.facebook.com/v26.0/${META_PIXEL}/events`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(8000),
    body: JSON.stringify({ access_token: META_TOKEN, data, ...(test ? { test_event_code: test } : {}) }),
  }).catch((e) => ({ ok: false, status: 0, text: async () => String(e) }) as Response)
  const texte = (await rep.text()).slice(0, 500)

  if (test) return reponse(rep.ok ? 200 : 502, { test: true, envoyees: rep.ok ? data.length : 0, meta: texte })

  // On note ce qui est parti (ou l'erreur) : la fiche l'affiche, et la
  // prochaine fois on n'envoie que ce qui manque.
  const maintenant = new Date().toISOString()
  for (const l of aEnvoyer) {
    await base(`/rest/v1/leads?id=eq.${l.id}`, {
      method: 'PATCH',
      body: JSON.stringify(rep.ok
        ? { meta_vente_valeur: l.cash_collecte, meta_vente_at: maintenant, meta_vente_erreur: null }
        : { meta_vente_erreur: `Meta a refusé (${rep.status}) : ${texte}`.slice(0, 500) }),
    })
  }
  if (!rep.ok) console.error('Meta a refusé les ventes', rep.status, texte)
  return reponse(rep.ok ? 200 : 502, { envoyees: rep.ok ? data.length : 0, meta: texte })
})
