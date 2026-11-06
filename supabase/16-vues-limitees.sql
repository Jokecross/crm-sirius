-- =====================================================================
--  Sirius — une vue réduite du CRM pour certains comptes
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  staff.vues : la liste des onglets autorisés. Vide, le compte a les
--  onglets normaux de son rôle. C'est un réglage d'affichage : le rôle du
--  compte reste celui de la base.
-- =====================================================================

alter table public.staff add column if not exists vues text[];

update public.staff s
   set vues = array['dashboard', 'classement', 'factures', 'rapport', 'sources']
  from auth.users u
 where u.id = s.user_id
   and u.email in ('atef.admin@loseless.agency', 'sirius.admin@loseless.agency');

-- Vérification : les deux comptes et leurs onglets.
select u.email, s.role, s.equipes, s.vues
  from public.staff s join auth.users u on u.id = s.user_id
 where s.vues is not null;
