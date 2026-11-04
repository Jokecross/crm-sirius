// =====================================================================
//  Paiement Whop de l'appel (9,99 €) — page de vente Sirius
//
//  La page affiche le formulaire de paiement Whop (Whop Elements) et en
//  tire un jeton à usage unique (ctok_…). Elle l'envoie ici : on crée le
//  paiement chez Whop avec la clé API, qui ne quitte jamais le serveur.
//  L'identifiant du lead part en metadata, pour que le webhook
//  (whop-webhook) le fasse passer d'« Opt-in » aux « Leads du jour ».
//
//  Secrets (Supabase → Edge Functions → Secrets) :
//    WHOP_API_KEY      clé API du compte Whop (permission payment:charge)
//    WHOP_ACCOUNT_ID   l'entreprise Whop, biz_…
//    WHOP_PLAN_ID      le plan à 9,99 €, plan_…
//  Le plan est fixé ici, pas par la page : on ne laisse pas un visiteur
//  choisir ce qu'il paie.
// =====================================================================

const WHOP_API_KEY = Deno.env.get('WHOP_API_KEY') ?? ''
const WHOP_ACCOUNT_ID = Deno.env.get('WHOP_ACCOUNT_ID') ?? ''
const PLAN = Deno.env.get('WHOP_PLAN_ID') ?? ''

// Les pages qui ont le droit d'appeler la fonction, et de servir d'adresse
// de retour après une étape bancaire (3D Secure).
const ORIGINES = [
  'https://www.iamoneyclub-starter.com',
  'https://iamoneyclub-starter.com',
  'https://lpsirius.vercel.app',
]

function entetes(origine: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origine && ORIGINES.includes(origine) ? origine : ORIGINES[0],
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
  }
}

Deno.serve(async (req) => {
  const h = entetes(req.headers.get('origin'))
  const reponse = (statut: number, corps: unknown) => new Response(JSON.stringify(corps), { status: statut, headers: h })

  if (req.method === 'OPTIONS') return new Response('ok', { headers: h })
  if (req.method !== 'POST') return reponse(405, { erreur: 'POST seulement' })
  if (!WHOP_API_KEY || !WHOP_ACCOUNT_ID || !PLAN) return reponse(500, { erreur: 'Paiement non configuré.' })

  let d: { lead_id?: string; confirmation_token?: string; email?: string; return_url?: string }
  try { d = await req.json() } catch { return reponse(400, { erreur: 'Requête invalide.' }) }

  if (!d.confirmation_token || !/^ctok_/.test(d.confirmation_token)) return reponse(400, { erreur: 'Moyen de paiement manquant.' })
  const lead = /^[0-9a-f-]{36}$/i.test(d.lead_id ?? '') ? d.lead_id! : null
  const retour = ORIGINES.some((o) => (d.return_url ?? '').startsWith(o + '/')) ? d.return_url : `${ORIGINES[0]}/?confirmation=1`

  const r = await fetch('https://api.whop.com/api/v1/payments', {
    method: 'POST',
    headers: { Authorization: `Bearer ${WHOP_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      account_id: WHOP_ACCOUNT_ID,
      // Whop l'appelle « variant » : c'est le plan_… de la page de paiement.
      variant_id: PLAN,
      confirmation_token: d.confirmation_token,
      ...(d.email ? { email: d.email } : {}),
      return_url: retour,
      metadata: lead ? { lead_id: lead } : {},
    }),
  })
  const texte = await r.text()
  let p: Record<string, unknown> = {}
  try { p = JSON.parse(texte) } catch { /* réponse vide ou HTML */ }

  if (!r.ok) {
    // Le message de Whop sert au diagnostic ; la page affiche un texte simple.
    console.error('Whop a refusé le paiement', r.status, texte.slice(0, 500))
    const msg = (p as { error?: { message?: string } }).error?.message
    return reponse(402, { erreur: msg ? `Paiement refusé : ${msg}` : 'Le paiement a été refusé. Réessaie.' })
  }
  // Le client_secret ne débloque que ce paiement-là (3D Secure) : il peut
  // repartir vers la page. La clé API, jamais.
  return reponse(200, { id: p.id ?? null, status: p.status ?? null, client_secret: p.client_secret ?? null })
})
