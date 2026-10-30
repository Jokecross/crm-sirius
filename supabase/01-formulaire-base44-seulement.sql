-- =====================================================================
--  Sirius — le formulaire public ne dépose que chez Base44
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Sans ça, quelqu'un qui appelle l'API à la main avec la clé anon pourrait
--  glisser un lead dans l'équipe Skool, ou dans le vivier du
--  parcours automatique (qui n'existe pas sur la page Sirius).
-- =====================================================================

drop policy if exists "public peut deposer un lead" on public.leads;
create policy "public peut deposer un lead"
  on public.leads for insert
  to anon
  with check (
    status = 'nouveau'
    and setter_id is null
    and called_at is null
    and notes is null
    and dials = 0
    and cash_collecte = 0
    and equipe = 'starter'        -- Base44, la seule équipe qui travaille le formulaire
    and vivier = 'formulaire'
    and auto_jeton is null
  );
