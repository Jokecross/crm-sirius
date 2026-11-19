-- =====================================================================
--  Sirius — l'Opt-in ouvert à toute l'équipe
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Avant : seuls trois setters (staff.voit_optin) voyaient l'onglet
--  Opt-in, et seulement les leads qu'on leur avait attribués. Les opt-in
--  sans setter n'étaient visibles que des administrateurs.
--
--  Maintenant : l'onglet Opt-in marche comme les Leads du jour. Chaque
--  setter de l'équipe voit les opt-in libres (sans setter) et les siens.
--  Il en prend un, il devient le sien, les autres ne le voient plus.
--  Les opt-in déjà attribués restent à leur setter.
-- =====================================================================

drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin()
         or (public.is_staff() and equipe = any(public.mes_equipes())
             and (vivier <> 'optin' or setter_id is null or setter_id = auth.uid())));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and equipe = any(public.mes_equipes())
              and (vivier <> 'optin' or setter_id is null or setter_id = auth.uid())))
  with check (public.is_admin()
              or (public.is_staff() and equipe = any(public.mes_equipes())
                  and (vivier <> 'optin' or setter_id is null or setter_id = auth.uid())));

notify pgrst, 'reload schema';

-- Vérification : les opt-in libres que toute l'équipe verra, et ceux déjà pris.
select case when setter_id is null then 'libres (visibles par toute l''équipe)' else 'déjà attribués' end as opt_in,
       count(*) as nombre
  from public.leads
 where vivier = 'optin'
 group by 1 order by 1;
