-- =====================================================================
--  Sirius — un seul lien de réservation pour toute l'équipe Skool
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 02-reservations-skool.sql (il fait aussi partie
--  d'INSTALLATION.sql, en dernier).
--
--  Le lien de l'équipe (<page de vente>/rdv, sans code) montre tous les
--  créneaux où au moins un setter Skool est libre. À la réservation,
--  l'appel va au setter libre à cette heure-là ; s'ils sont plusieurs,
--  à celui qui a le moins d'appels réservés ce jour-là, puis le moins
--  d'appels à venir, puis au hasard.
--
--  Les liens personnels (/rdv/<code>) marchent toujours : même fonctions,
--  avec un code.
--
--  Seuls les setters comptent (pas les administrateurs, qui ont accès à
--  l'équipe Skool pour la voir, pas pour prendre des appels).
-- =====================================================================

-- Les setters de l'équipe Skool, actifs.
create or replace function public.rdv_setters_equipe()
returns setof public.staff
language sql stable security definer set search_path = public
as $$
  select s.* from public.staff s
  where s.actif
    and s.role = 'setter'
    and 'skool' = any(coalesce(s.equipes, array[s.equipe]));
$$;

revoke all on function public.rdv_setters_equipe() from public, anon, authenticated;

-- Ce que voit le public. Sans code : les créneaux de toute l'équipe,
-- sans prénom (on ne sait pas encore qui appellera).
create or replace function public.rdv_calendrier(p_code text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  s public.staff;
  r public.crm_reglages;
begin
  select * into r from public.crm_reglages where id = 1;

  if coalesce(btrim(p_code), '') = '' then
    return jsonb_build_object(
      'prenom',   null,
      'duree',    r.rdv_duree_min,
      'creneaux', coalesce((
        select jsonb_agg(d order by d) from (
          select distinct c.debut as d
          from public.rdv_setters_equipe() e,
               lateral public.rdv_creneaux_setter(e.user_id) c
        ) x), '[]'::jsonb)
    );
  end if;

  s := public.rdv_setter(p_code);
  if s.user_id is null then return null; end if;
  return jsonb_build_object(
    'prenom',   s.first_name,
    'duree',    r.rdv_duree_min,
    'creneaux', coalesce((select jsonb_agg(c.debut order by c.debut)
                          from public.rdv_creneaux_setter(s.user_id) c), '[]'::jsonb)
  );
end;
$$;

-- Réserver. Sans code : le setter est choisi ici, au moment de réserver.
create or replace function public.rdv_reserver(
  p_code      text,
  p_debut     timestamptz,
  p_prenom    text,
  p_nom       text,
  p_email     text,
  p_telephone text,
  p_page_url  text default null,
  p_source    text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  s     public.staff;
  r     public.crm_reglages;
  qui   uuid;
  tel   text := regexp_replace(coalesce(p_telephone, ''), '[^0-9+]', '', 'g');
  jour0 timestamptz := date_trunc('day', p_debut);
begin
  -- Une réservation à la fois pour toute l'équipe : la vérification du
  -- créneau, le choix du setter et l'insertion ne se croisent jamais.
  perform pg_advisory_xact_lock(hashtext('rdv:skool'));

  if coalesce(btrim(p_code), '') <> '' then
    s := public.rdv_setter(p_code);
    if s.user_id is null then
      raise exception 'Ce lien de réservation n''existe plus.' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.rdv_creneaux_setter(s.user_id) c where c.debut = p_debut) then
      qui := s.user_id;
    end if;
  else
    select e.user_id into qui
    from public.rdv_setters_equipe() e
    where exists (select 1 from public.rdv_creneaux_setter(e.user_id) c where c.debut = p_debut)
    order by
      (select count(*) from public.leads l
        where l.setter_id = e.user_id and l.rdv_annule_at is null
          and l.rdv_at >= jour0 and l.rdv_at < jour0 + interval '1 day'),
      (select count(*) from public.leads l
        where l.setter_id = e.user_id and l.rdv_annule_at is null and l.rdv_at > now()),
      random()
    limit 1;
  end if;

  if qui is null then
    raise exception 'Ce créneau vient d''être pris. Choisis-en un autre.' using errcode = 'P0001';
  end if;

  -- Un même numéro n'a qu'un appel à venir dans l'équipe.
  if exists (select 1 from public.leads
             where equipe = 'skool' and phone = tel
               and rdv_at > now() and rdv_annule_at is null) then
    raise exception 'Tu as déjà un appel réservé. On te contacte à l''heure prévue.'
      using errcode = 'P0001';
  end if;

  select * into r from public.crm_reglages where id = 1;
  select * into s from public.staff where user_id = qui;

  insert into public.leads (
    first_name, last_name, email, phone, page_url, source,
    equipe, vivier, status, setter_id,
    rdv_at, rdv_fin_at, rdv_reserve_at
  ) values (
    btrim(p_prenom), btrim(p_nom), lower(btrim(p_email)), tel,
    left(p_page_url, 300), left(p_source, 300),
    'skool', 'formulaire', 'nouveau', qui,
    p_debut, p_debut + make_interval(mins => r.rdv_duree_min), now()
  );

  return jsonb_build_object('ok', true, 'prenom', s.first_name,
                            'debut', p_debut, 'duree', r.rdv_duree_min);
end;
$$;

revoke all on function public.rdv_calendrier(text) from public;
revoke all on function public.rdv_reserver(text, timestamptz, text, text, text, text, text, text) from public;
grant execute on function public.rdv_calendrier(text) to anon, authenticated;
grant execute on function public.rdv_reserver(text, timestamptz, text, text, text, text, text, text) to anon, authenticated;

-- Vérification : les setters de l'équipe, et le nombre de créneaux libres de chacun.
select e.first_name, (select count(*) from public.rdv_creneaux_setter(e.user_id)) as creneaux_libres
from public.rdv_setters_equipe() e
order by e.first_name;
