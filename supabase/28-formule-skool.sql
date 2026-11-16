-- =====================================================================
--  Sirius — la formule « Skool » de l'espace membre : le workshop seul
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Les clients venus du Skool regardent leurs modules vidéo sur Skool.
--  Dans l'espace membre, ils n'ont que le workshop de 7 jours : le sales
--  choisit « Skool · workshop seul » en générant le lien d'accès.
--    - aucun module vidéo n'entre dans cette formule, même par erreur ;
--    - pas de contrat de garantie (réservé aux clients de la page de vente).
-- =====================================================================

insert into public.plans (code, label, rank, dernier_module) values
  ('skool', 'Skool · workshop seul', 4, 0)
on conflict (code) do update
  set label = excluded.label, rank = excluded.rank, dernier_module = excluded.dernier_module;

-- Par sécurité : si des modules y avaient été cochés, on les retire.
delete from public.plan_modules where plan_code = 'skool';

-- Aucun module ne se coche dans la formule Skool : la demande est ignorée.
create or replace function public.skool_sans_module()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.plan_code = 'skool' then return null; end if;
  return new;
end;
$$;

drop trigger if exists trg_skool_sans_module on public.plan_modules;
create trigger trg_skool_sans_module
  before insert or update on public.plan_modules
  for each row execute function public.skool_sans_module();

-- Pas de contrat de garantie sur un lien Skool.
create or replace function public.skool_sans_contrat()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from invites i where i.token = new.token and i.plan_code = 'skool') then
    raise exception 'Pas de contrat de garantie pour cette formule' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_skool_sans_contrat on public.contrats;
create trigger trg_skool_sans_contrat
  before insert on public.contrats
  for each row execute function public.skool_sans_contrat();

-- Vérification : les quatre formules, et 0 module pour Skool.
select p.code, p.label, p.rank,
       (select count(*) from public.plan_modules pm where pm.plan_code = p.code) as modules
  from public.plans p order by p.rank;
