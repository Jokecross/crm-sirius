-- =====================================================================
--  Sirius — le classement des setters, pour toute l'équipe
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Ordre : le cash collecté, puis le nombre de closings, puis le % de
--  closing. Un bon pourcentage sur deux ventes ne passe donc jamais devant
--  quelqu'un qui a rapporté plus.
--
--  Même définition que le reste du CRM : un closing est une vente posée sur
--  la période (closed_at), un joint un lead dans un statut de joint. Les
--  joints comptés sont ceux reçus ou closés sur la période, pour que le %
--  ne dépasse jamais 100. Pas de commissions ici : chacun voit le classement.
-- =====================================================================

create or replace function public.classement_setters(p_du date, p_au date, p_equipe text)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  debut timestamptz := coalesce(p_du::timestamp at time zone 'Europe/Paris', '-infinity'::timestamptz);
  fin   timestamptz := coalesce((p_au + 1)::timestamp at time zone 'Europe/Paris', 'infinity'::timestamptz);
  resultat json;
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
  lignes as (
    select s.user_id,
      trim(coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, '')) as nom,
      coalesce(v.cash, 0)     as cash,
      coalesce(v.closings, 0) as closings,
      coalesce(j.joints, 0)   as joints,
      case when coalesce(j.joints, 0) > 0
           then round(coalesce(v.closings, 0)::numeric / j.joints * 100, 1) else 0 end as taux
    from public.staff s
    left join ventes v on v.setter_id = s.user_id
    left join joints j on j.setter_id = s.user_id
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
