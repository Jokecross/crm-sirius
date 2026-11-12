-- =====================================================================
--  Sirius — la page vérifie le paiement avant d'afficher « C'est payé »
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  paiement_confirme(lead) dit seulement si Whop a confirmé le paiement
--  de ce lead (paye_at posé par le webhook). Rien d'autre ne sort : ni nom,
--  ni contact. L'identifiant du lead est aléatoire et ne circule que dans
--  la page de la personne qui vient de payer.
-- =====================================================================

create or replace function public.paiement_confirme(p_lead uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select paye_at is not null from leads where id = p_lead), false);
$$;

revoke all on function public.paiement_confirme(uuid) from public;
grant execute on function public.paiement_confirme(uuid) to anon, authenticated;

notify pgrst, 'reload schema';

select public.paiement_confirme('00000000-0000-0000-0000-000000000000') as test_doit_etre_false;
