-- =====================================================================
--  Sirius — qui voit les paiements Base44 (Affiliate Consulting)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  staff.voit_affiliate : seul un compte qui a ce droit lit les événements
--  et voit l'onglet « Base44 » du CRM. Le droit se donne à part, compte par
--  compte (le fichier qui le donne n'est pas dans le dépôt).
-- =====================================================================

alter table public.staff add column if not exists voit_affiliate boolean not null default false;

drop policy if exists "martin lit les evenements affiliate" on public.affiliate_events;
drop policy if exists "lecture des evenements affiliate" on public.affiliate_events;
create policy "lecture des evenements affiliate" on public.affiliate_events
  for select to authenticated
  using (exists (select 1 from public.staff where user_id = auth.uid() and voit_affiliate));
