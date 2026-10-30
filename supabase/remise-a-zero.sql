-- =====================================================================
--  REMISE À ZÉRO
--
--  Supprime tous les leads — vivier du jour, pipelines, relances,
--  archive, iClosed. Partent avec eux, en cascade : les factures, les
--  enregistrements d'appel et le journal d'activité.
--
--  Rien ne se récupère. Ne sont pas touchés : les comptes de l'équipe,
--  les tarifs, l'espace membre, et les fichiers déjà dans les seaux.
-- =====================================================================

with efface as (
  delete from public.leads returning 1
)
select count(*) as leads_supprimes from efface;

-- Le verdict. Tout doit afficher zéro.
select (select count(*) from public.leads)      as leads_restants,
       (select count(*) from public.invoices)   as factures_restantes,
       (select count(*) from public.lead_calls) as enregistrements_restants;

-- ---------------------------------------------------------------------
-- Les fichiers
-- ---------------------------------------------------------------------
-- Postgres ne commande pas au stockage : les PDF de factures et les
-- enregistrements audio restent dans leurs seaux. Pour les vider :
-- Supabase → Storage → « factures » et « appels » → tout sélectionner →
-- Delete.
