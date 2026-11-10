-- =====================================================================
--  Sirius — l'Opt-in ouvert à quelques setters, et la répartition
--  À coller dans Supabase → SQL Editor → New query → Run.
--
--  1. staff.voit_optin : un setter qui a ce droit voit, dans l'onglet
--     Opt-in, les leads non payés qui lui sont attribués. Jamais ceux des
--     autres, jamais ceux qui ne sont à personne.
--  2. Valentin, Lohan et ArthurL reçoivent ce droit.
--  3. Les opt-in encore « Nouveau », sans setter et arrivés il y a plus de
--     30 minutes, sont partagés entre eux trois, à tour de rôle, du plus
--     ancien au plus récent.
-- =====================================================================

alter table public.staff add column if not exists voit_optin boolean not null default false;

update public.staff s set voit_optin = true
  from auth.users u
 where u.id = s.user_id
   and u.email in ('valentin.base44@loseless.agency', 'lohan.base44@loseless.agency', 'arthurl.sirius@loseless.agency');

drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin()
         or (public.is_staff() and equipe = any(public.mes_equipes())
             and (vivier <> 'optin'
                  or (setter_id = auth.uid()
                      and exists (select 1 from public.staff where user_id = auth.uid() and voit_optin)))));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and equipe = any(public.mes_equipes())
              and (vivier <> 'optin'
                   or (setter_id = auth.uid()
                       and exists (select 1 from public.staff where user_id = auth.uid() and voit_optin)))))
  with check (public.is_admin()
              or (public.is_staff() and equipe = any(public.mes_equipes())
                  and (vivier <> 'optin'
                       or (setter_id = auth.uid()
                           and exists (select 1 from public.staff where user_id = auth.uid() and voit_optin)))));

-- La répartition, en une fois.
with trois as (
  select s.user_id, row_number() over (order by u.email) - 1 as k
    from public.staff s join auth.users u on u.id = s.user_id
   where u.email in ('valentin.base44@loseless.agency', 'lohan.base44@loseless.agency', 'arthurl.sirius@loseless.agency')
),
a_partager as (
  select id, row_number() over (order by created_at) - 1 as n
    from public.leads
   where vivier = 'optin' and status = 'nouveau' and setter_id is null and equipe = 'starter'
     and created_at < now() - interval '30 minutes'
)
update public.leads l
   set setter_id = t.user_id
  from a_partager p
  join trois t on t.k = p.n % 3
 where l.id = p.id;

-- Vérification : combien chacun a reçu.
select s.first_name, s.voit_optin, count(l.id) as opt_in_attribues
  from public.staff s
  left join public.leads l on l.setter_id = s.user_id and l.vivier = 'optin' and l.status = 'nouveau'
 where s.voit_optin
 group by s.first_name, s.voit_optin
 order by s.first_name;
