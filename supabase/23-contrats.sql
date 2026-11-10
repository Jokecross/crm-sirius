-- =====================================================================
--  Sirius — le contrat de garantie « Premier client en 7 jours », en ligne
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Chaque lien d'invitation a son contrat : /contrat/<token>. Le client
--  l'ouvre sans compte, remplit son nom, signe avec le doigt, et c'est
--  enregistré une fois pour toutes (pas de modification après signature).
--  L'équipe (setters et administrateurs) voit qui a signé.
--
--  La date d'entrée dans le programme est celle de la création du lien
--  d'invitation, c'est-à-dire du closing.
-- =====================================================================

create table if not exists public.contrats (
  token       uuid primary key references public.invites(token) on delete cascade,
  prenom      text not null check (char_length(prenom) between 1 and 80),
  nom         text not null check (char_length(nom) between 1 and 80),
  email       text not null check (char_length(email) between 3 and 160),
  telephone   text not null check (char_length(telephone) between 6 and 30),
  signature   text not null check (signature like 'data:image/png;base64,%' and char_length(signature) < 400000),
  signe_at    timestamptz not null default now(),
  navigateur  text
);

alter table public.contrats enable row level security;
revoke all on public.contrats from anon, authenticated;
grant select on public.contrats to authenticated;

drop policy if exists "equipe lit les contrats" on public.contrats;
create policy "equipe lit les contrats" on public.contrats
  for select to authenticated using (public.is_equipe(auth.uid()));

-- Le contrat d'un lien : la formule, la date d'entrée, et la signature si
-- elle existe. Rien sans le bon token.
create or replace function public.contrat_lire(p_token uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'formule',     p.label,
    'date_entree', (i.created_at at time zone 'Europe/Paris')::date,
    'pour',        i.label,
    'signe',       c.signe_at is not null,
    'prenom',      c.prenom,
    'nom',         c.nom,
    'email',       c.email,
    'telephone',   c.telephone,
    'signature',   c.signature,
    'signe_at',    c.signe_at
  )
  from invites i
  join plans p on p.code = i.plan_code
  left join contrats c on c.token = i.token
  where i.token = p_token
    and i.created_at > now() - interval '120 days';
$$;

create or replace function public.contrat_signer(
  p_token uuid, p_prenom text, p_nom text, p_email text, p_telephone text, p_signature text, p_navigateur text default null)
returns timestamptz
language plpgsql security definer set search_path = public
as $$
declare
  v_quand timestamptz;
begin
  if not exists (select 1 from invites where token = p_token and created_at > now() - interval '120 days') then
    raise exception 'Contrat introuvable' using errcode = 'P0002';
  end if;
  if exists (select 1 from contrats where token = p_token) then
    raise exception 'Ce contrat est déjà signé' using errcode = '23505';
  end if;
  insert into contrats (token, prenom, nom, email, telephone, signature, navigateur)
  values (p_token, trim(p_prenom), trim(p_nom), lower(trim(p_email)), trim(p_telephone), p_signature, left(p_navigateur, 300))
  returning signe_at into v_quand;
  return v_quand;
end;
$$;

revoke all on function public.contrat_lire(uuid) from public;
revoke all on function public.contrat_signer(uuid, text, text, text, text, text, text) from public;
grant execute on function public.contrat_lire(uuid) to anon, authenticated;
grant execute on function public.contrat_signer(uuid, text, text, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Vérification.
select count(*) as contrats from public.contrats;
