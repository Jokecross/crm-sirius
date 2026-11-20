-- =====================================================================
--  Sirius — les ventes Skool envoyées à Meta
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  La fonction meta-vente envoie à Meta la vraie valeur de chaque vente
--  Skool. Elle note ici ce qui est parti, pour ne jamais envoyer deux fois
--  la même vente, et l'erreur si Meta refuse.
-- =====================================================================

alter table public.leads
  add column if not exists meta_vente_valeur numeric,
  add column if not exists meta_vente_at     timestamptz,
  add column if not exists meta_vente_erreur text;

comment on column public.leads.meta_vente_valeur is
  'Montant de la vente déjà envoyé à Meta (API Conversions). Si cash_collecte devient plus grand (montée d''abonnement), seule la différence repart.';

notify pgrst, 'reload schema';

-- Vérification : les ventes Skool des 7 derniers jours, que la fonction
-- enverra à son premier passage.
select first_name, status::text as abonnement, cash_collecte, closed_at
  from public.leads
 where (offre = 'skool' or equipe = 'skool')
   and status::text in ('monthly', 'yearly', 'yearly_builder')
   and closed_at >= now() - interval '7 days'
   and cash_collecte > 0
 order by closed_at;
