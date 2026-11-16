-- WA-100 / Core issue #540: legacy send-whatsapp wrote interaction_type='whatsapp'
-- to public.client_interactions while the production constraint rejected it.
-- Forward-only, narrow schema compatibility repair. Does not send messages,
-- modify historical interaction rows, or imply provider delivery success.

begin;
do $wa100_contract$
declare v_existing text;
begin
  if to_regclass('public.client_interactions') is null then
    raise exception 'WA100_INTERACTIONS_TABLE_MISSING';
  end if;
  select pg_get_constraintdef(c.oid) into v_existing
  from pg_constraint c
  where c.conrelid='public.client_interactions'::regclass
    and c.conname='client_interactions_interaction_type_check'
    and c.contype='c';
  if v_existing is null
     or position('call' in v_existing)=0
     or position('visit' in v_existing)=0
     or position('email' in v_existing)=0
     or position('complaint' in v_existing)=0
     or position('whatsapp' in v_existing)>0 then
    raise exception 'WA100_INTERACTIONS_CONSTRAINT_DRIFT';
  end if;
end;
$wa100_contract$;

alter table public.client_interactions
  drop constraint client_interactions_interaction_type_check;
alter table public.client_interactions
  add constraint client_interactions_interaction_type_check
  check (
    interaction_type is null
    or interaction_type in ('call','visit','email','complaint','whatsapp')
  );

commit;
