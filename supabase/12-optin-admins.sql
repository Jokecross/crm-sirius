-- =====================================================================
--  Sirius — le vivier « Opt-in » ne regarde que les administrateurs
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Un setter ne lit ni ne modifie un lead tant qu'il est en opt-in. Dès que
--  Whop confirme le paiement, le lead passe dans « formulaire » : il
--  apparaît alors dans les Leads du jour, pour toute l'équipe.
--  La fonction whop_paiement_recu n'est pas concernée par ces règles.
-- =====================================================================

drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin()
         or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'))
  with check (public.is_admin()
              or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'));

-- Vérification : deux lignes, chacune mentionne optin.
select policyname, cmd, qual like '%optin%' as optin_exclu
  from pg_policies
 where schemaname = 'public' and tablename = 'leads'
   and policyname in ('staff lit les leads', 'staff modifie les leads');
