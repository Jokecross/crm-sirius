-- =====================================================================
--  Sirius — les trois formules de l'espace membre
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--    Mensuel Builder   modules 1 à 8
--    Annuel Starter    modules 1 à 14
--    Annuel Builder    modules 1 à 20
--
--  Les codes « mensuel » et « annuel » restent : les comptes et les liens
--  déjà créés ne bougent pas, seul leur nom change. Un nouveau module se
--  coche tout seul dans les bonnes formules ; l'onglet Formules du
--  back-office permet toujours de changer une case à la main.
--  Les introductions et les bonus ne comptent pas dans la numérotation.
-- =====================================================================

alter table public.plans add column if not exists dernier_module int;

comment on column public.plans.dernier_module is
  'Le dernier module compris dans la formule : un nouveau module y est coché jusqu''à ce numéro.';

insert into public.plans (code, label, rank, dernier_module) values
  ('mensuel',        'Mensuel Builder', 1, 8),
  ('annuel',         'Annuel Starter',  2, 14),
  ('annuel_builder', 'Annuel Builder',  3, 20)
on conflict (code) do update
  set label = excluded.label, rank = excluded.rank, dernier_module = excluded.dernier_module;

create or replace function public.module_dans_les_formules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_numero int;
begin
  if new.is_intro is true or new.is_bonus is true then
    return new;
  end if;

  select count(*) into v_numero
    from modules m
   where m.is_intro is not true
     and m.is_bonus is not true
     and m.position <= new.position;

  insert into plan_modules (plan_code, module_id)
  select code, new.id from plans where dernier_module >= v_numero
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists trg_module_dans_les_formules on public.modules;
create trigger trg_module_dans_les_formules
  after insert on public.modules
  for each row execute function public.module_dans_les_formules();

-- Vérification.
select code, label, rank, dernier_module from public.plans order by rank;
