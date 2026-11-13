-- =====================================================================
--  Sirius — les leads de la page de réservation Skool
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  La page de réservation (page-reservation.vercel.app) n'a plus de
--  calendrier : un formulaire (prénom, nom, e-mail, WhatsApp) dépose le
--  lead dans les Leads du jour de l'équipe Base44, comme la page de vente,
--  avec offre = 'skool'. Le CRM lui met la pastille « Skool » : le sales
--  sait qu'il applique la trame Skool.
--
--  Rien d'autre ne change : le formulaire public reste limité à l'équipe
--  Base44 et au vivier « formulaire » (politique de 09-optin-whop.sql).
-- =====================================================================

alter table public.leads drop constraint if exists leads_offre_check;
alter table public.leads add constraint leads_offre_check
  check (offre in ('sirius', 'jvj', 'skool'));

comment on column public.leads.offre is
  'La page qui a amené le lead : sirius (page de vente Sirius), jvj (page JVJ), skool (page de réservation Skool).';

-- Vérification : une ligne par page, avec le nombre de leads.
select offre, count(*) as leads from public.leads group by offre order by offre;
