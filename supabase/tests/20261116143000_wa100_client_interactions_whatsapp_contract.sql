-- Contract for 20261116143000_wa100_client_interactions_whatsapp_contract.sql
-- WA-100 / #540: client interaction timeline must accept WhatsApp event type.
-- pgTAP negative SQLSTATE test uses properly paired dollar-quoted input.
begin;
select plan(8);

select has_table('public','client_interactions','timeline table exists');
select ok(
  exists(select 1 from pg_constraint
    where conrelid='public.client_interactions'::regclass
      and conname='client_interactions_interaction_type_check'
      and position('whatsapp' in pg_get_constraintdef(oid))>0),
  'schema permits explicitly governed WhatsApp interaction type');

select lives_ok($$
  insert into public.client_interactions(interaction_type, notes, outcome)
  values ('whatsapp','WA100 TEST ONLY','sent')
$$,'WhatsApp sender can record provider-accepted timeline item without delivery claim');

select lives_ok($$
  insert into public.client_interactions(interaction_type, notes)
  values ('call','WA100 TEST ONLY'),('visit','WA100 TEST ONLY'),
         ('email','WA100 TEST ONLY'),('complaint','WA100 TEST ONLY')
$$,'preexisting interaction types remain valid');
select is((select count(*)::integer from public.client_interactions
           where notes='WA100 TEST ONLY' and interaction_type='whatsapp'),
          1,'exactly one WhatsApp fixture row persisted');
select is((select count(*)::integer from public.client_interactions
           where notes='WA100 TEST ONLY' and interaction_type in ('call','visit','email','complaint')),
          4,'all four legacy interaction types remain valid');
select throws_ok($$
  insert into public.client_interactions(interaction_type, notes)
  values ('unverified_external_channel','WA100 TEST ONLY')
$$,'23514');
select ok(
  (select count(*) from pg_constraint where conrelid='public.client_interactions'::regclass
    and conname='client_interactions_interaction_type_check')=1,
  'exactly one named type check remains');

select * from finish();
rollback;
