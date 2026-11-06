-- =====================================================================
--  Sirius — le classement, avec le connection rate pour les administrateurs
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Même classement que 15-classement.sql. En plus, pour les administrateurs
--  en vue complète : le connection rate de chaque setter, calculé comme dans
--  crm_stats : joints / appelés, sur les leads reçus pendant la période.
--  Les setters et les comptes en vue réduite reçoivent ces champs vides.
-- =====================================================================

create or replace function public.classement_setters(p_du date, p_au date, p_equipe text)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  debut timestamptz := coalesce(p_du::timestamp at time zone 'Europe/Paris', '-infinity'::timestamptz);
  fin   timestamptz := coalesce((p_au + 1)::timestamp at time zone 'Europe/Paris', 'infinity'::timestamptz);
  resultat json;
  v_complet boolean := public.is_admin() and not exists (
    select 1 from public.staff where user_id = auth.uid() and vues is not null);
begin
  if not (public.is_admin() or (public.is_staff() and p_equipe = any(public.mes_equipes()))) then
    raise exception 'Réservé à l''équipe' using errcode = '42501';
  end if;

  with
  ventes as (
    select setter_id, count(*) as closings, coalesce(sum(cash_collecte), 0) as cash
    from public.leads
    where equipe = p_equipe and setter_id is not null
      and status::text in ('monthly', 'yearly', 'yearly_builder')
      and closed_at is not null and closed_at >= debut and closed_at < fin
    group by setter_id
  ),
  joints as (
    select setter_id, count(*) as joints
    from public.leads
    where equipe = p_equipe and setter_id is not null
      and status::text in ('follow_up', 'monthly', 'yearly', 'yearly_builder', 'ghosted', 'time_waster')
      and ((created_at >= debut and created_at < fin)
           or (closed_at is not null and closed_at >= debut and closed_at < fin))
    group by setter_id
  ),
  connexion as (
    select setter_id,
      count(*) filter (where dials > 0) as tentes,
      count(*) filter (where status::text in
        ('follow_up', 'monthly', 'yearly', 'yearly_builder', 'ghosted', 'time_waster')) as joints_recus
    from public.leads
    where equipe = p_equipe and setter_id is not null
      and created_at >= debut and created_at < fin
    group by setter_id
  ),
  lignes as (
    select s.user_id,
      trim(coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, '')) as nom,
      coalesce(v.cash, 0)     as cash,
      coalesce(v.closings, 0) as closings,
      coalesce(j.joints, 0)   as joints,
      case when coalesce(j.joints, 0) > 0
           then round(coalesce(v.closings, 0)::numeric / j.joints * 100, 1) else 0 end as taux,
      case when v_complet then coalesce(c.tentes, 0) end as tentes,
      case when v_complet then
        case when coalesce(c.tentes, 0) > 0
             then round(coalesce(c.joints_recus, 0)::numeric / c.tentes * 100) else 0 end
      end as connexion
    from public.staff s
    left join ventes v on v.setter_id = s.user_id
    left join joints j on j.setter_id = s.user_id
    left join connexion c on c.setter_id = s.user_id
    where s.role = 'setter' and s.actif
      and p_equipe = any(coalesce(s.equipes, array[s.equipe]))
  ),
  classees as (
    select l.*, row_number() over (order by cash desc, closings desc, taux desc, nom) as rang
    from lignes l
  )
  select json_build_object(
    'lignes', coalesce((select json_agg(c order by c.rang) from classees c), '[]'::json),
    'maj', now()
  ) into resultat;

  return resultat;
end;
$$;

revoke all on function public.classement_setters(date, date, text) from public, anon;
grant execute on function public.classement_setters(date, date, text) to authenticated;

notify pgrst, 'reload schema';

-- Vérification : la fonction est là.
select proname from pg_proc where proname = 'classement_setters';
