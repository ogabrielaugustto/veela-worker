begin;

create or replace function public.execute_case_operational_action(
  p_organization_id uuid, p_case_public_id integer, p_detection_id uuid,
  p_action text, p_notes text, p_paid_amount integer default null,
  p_paid_date date default null, p_payment_method text default null,
  p_payment_reference text default null
) returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_detection public.detections%rowtype;
  v_workflow public.case_workflows%rowtype;
  v_settlement public.case_settlements%rowtype;
  v_stage text;
  v_event text;
  v_title text;
  v_item public.detections%rowtype;
begin
  if v_user_id is null or not public.is_admin_user() or not exists (select 1 from public.profiles where id = v_user_id and is_active) then
    raise exception 'Acesso negado';
  end if;
  if p_action not in ('follow_up', 'call', 'internal_note', 'register_payment', 'legal', 'close_resolved') then
    raise exception 'Ação inválida';
  end if;
  if p_action <> 'register_payment' and (p_notes is null or length(trim(p_notes)) < 1 or length(p_notes) > 4000) then
    raise exception 'Informe a descrição da ação';
  end if;
  select * into v_detection from public.detections
    where id = p_detection_id and organization_id = p_organization_id
      and case_public_id = p_case_public_id and archived_at is null for update;
  if not found then raise exception 'Caso não encontrado'; end if;
  select * into v_settlement from public.case_settlements where organization_id = p_organization_id and case_public_id = p_case_public_id;
  v_stage := case
    when v_detection.status = 'resolved' then 'closed'
    when v_settlement.status = 'paid' then 'payment'
    when v_settlement.status in ('overdue', 'collections') then 'collections'
    when v_settlement.status = 'sra_signature_pending' then 'agreement_signature'
    when v_settlement.status is not null and v_settlement.status <> 'draft' then 'negotiation'
    else coalesce((select case
      when event_kind = 'documentation_notice' then 'documentation_notice'
      when event_kind = 'first_notice' then 'first_notice'
      when event_kind in ('doubt', 'debate', 'follow_up', 'call', 'other') then 'treatment'
      when event_kind = 'c2' then 'legal' else 'documents' end
      from public.case_events where organization_id = p_organization_id and case_public_id = p_case_public_id
      order by occurred_at desc limit 1), 'documents') end;
  insert into public.case_workflows (organization_id, case_public_id, representative_detection_id, stage, created_by_user_id, updated_by_user_id)
    values (p_organization_id, p_case_public_id, p_detection_id, v_stage, v_user_id, v_user_id)
    on conflict (organization_id, case_public_id) do nothing;
  select * into v_workflow from public.case_workflows
    where organization_id = p_organization_id and case_public_id = p_case_public_id for update;
  if v_workflow.stage = 'closed' or v_detection.status = 'resolved' then raise exception 'Este caso já está encerrado'; end if;
  if exists (select 1 from public.case_events where organization_id = p_organization_id and case_public_id = p_case_public_id and metadata->>'sendStatus' = 'pending') then raise exception 'Existe envio pendente neste caso'; end if;
  case p_action
    when 'follow_up' then v_stage := 'treatment'; v_event := 'follow_up'; v_title := 'Follow-up';
    when 'call' then v_stage := 'treatment'; v_event := 'call'; v_title := 'Ligação';
    when 'internal_note' then v_stage := v_workflow.stage; v_event := 'note'; v_title := 'Nota interna';
    when 'legal' then v_stage := 'legal'; v_event := 'legal'; v_title := 'Encaminhar jurídico';
    when 'close_resolved' then v_stage := 'closed'; v_event := 'status_change'; v_title := 'Fechar como resolvido';
    when 'register_payment' then v_stage := 'payment'; v_event := 'payment'; v_title := 'Registrar pagamento';
  end case;
  if p_action = 'register_payment' then
    select * into v_settlement from public.case_settlements
      where organization_id = p_organization_id and case_public_id = p_case_public_id for update;
    if not found or v_settlement.proposed_amount_cents is null or v_settlement.proposed_amount_cents <= 0
       or v_settlement.status not in ('sra_signed', 'payment_pending', 'overdue', 'collections')
       or not exists (select 1 from public.case_documents where organization_id = p_organization_id
         and case_public_id = p_case_public_id and document_kind = 'sra' and is_current and status in ('signed', 'attached')) then
      raise exception 'É necessário um SRA e um acordo pendente com valor definido';
    end if;
    if p_paid_amount is null or p_paid_amount < v_settlement.proposed_amount_cents or p_paid_date is null
       or p_payment_method not in ('pix', 'boleto', 'transfer', 'other') or p_payment_method is null then
      raise exception 'Informe o pagamento integral, data e forma válidas';
    end if;
    update public.case_settlements set status = 'paid', paid_amount_cents = p_paid_amount,
      paid_at = p_paid_date::timestamp at time zone 'America/Sao_Paulo', payment_method = p_payment_method,
      payment_reference = nullif(trim(p_payment_reference), ''), updated_by_user_id = v_user_id
      where id = v_settlement.id;
  end if;
  if p_action = 'close_resolved' then
    for v_item in select * from public.detections d where d.organization_id = p_organization_id
      and d.case_public_id = p_case_public_id and d.asset_id = v_detection.asset_id and d.archived_at is null
      and public.normalize_detection_case_key(d.asset_id, d.domain, d.source_url, d.canonical_source_url) =
        public.normalize_detection_case_key(v_detection.asset_id, v_detection.domain, v_detection.source_url, v_detection.canonical_source_url)
      and d.status <> 'resolved' for update
    loop
      update public.detections set status = 'resolved', reviewed_at = now(), reviewed_by_user_id = v_user_id where id = v_item.id and organization_id = p_organization_id;
      insert into public.detection_actions (organization_id, detection_id, user_id, action, from_status, to_status, notes, metadata)
        values (p_organization_id, v_item.id, v_user_id, 'marcada_como_resolvida', v_item.status, 'resolved', p_notes, jsonb_build_object('scope', 'case_action', 'reason', p_action));
    end loop;
  end if;
  insert into public.case_events (organization_id, case_public_id, workflow_id, detection_id, user_id, event_kind, direction, title, notes, metadata)
    values (p_organization_id, p_case_public_id, v_workflow.id, p_detection_id, v_user_id, v_event, 'internal', v_title,
      nullif(trim(p_notes), ''), jsonb_build_object('actionKind', p_action, 'paidAmountCents', p_paid_amount, 'paymentDate', p_paid_date, 'paymentMethod', p_payment_method));
  update public.case_workflows set stage = v_stage, updated_by_user_id = v_user_id where id = v_workflow.id and organization_id = p_organization_id;
end;
$$;
revoke all on function public.execute_case_operational_action(uuid, integer, uuid, text, text, integer, date, text, text) from public, anon;
grant execute on function public.execute_case_operational_action(uuid, integer, uuid, text, text, integer, date, text, text) to authenticated;

create unique index case_pending_financial_communication on public.case_events (organization_id, case_public_id)
where metadata->>'sendStatus' = 'pending';

create or replace function public.reserve_case_financial_communication(
 p_id uuid, p_organization_id uuid, p_case_public_id integer, p_detection_id uuid, p_action text,
 p_to text, p_subject text, p_body text, p_notes text, p_amount integer
) returns text language plpgsql security invoker set search_path = '' as $$
declare v_event public.case_events%rowtype; v_workflow public.case_workflows%rowtype; v_settlement public.case_settlements%rowtype;
begin
 if auth.uid() is null or not public.is_admin_user() or not exists (select 1 from public.profiles where id = auth.uid() and is_active) then raise exception 'Acesso negado'; end if;
 if p_action not in ('negotiation', 'collections') or p_to is null or length(trim(p_to)) = 0
   or length(trim(p_subject)) < 3 or length(trim(p_body)) < 10 or length(p_body) > 12000 then raise exception 'Dados inválidos'; end if;
 perform 1 from public.detections where id = p_detection_id and organization_id = p_organization_id and case_public_id = p_case_public_id and archived_at is null and status <> 'resolved' for update;
 if not found then raise exception 'Caso não encontrado ou encerrado'; end if;
 select * into v_workflow from public.case_workflows where organization_id = p_organization_id and case_public_id = p_case_public_id for update;
 if v_workflow.stage = 'closed' then raise exception 'Caso encerrado'; end if;
 select * into v_event from public.case_events where id = p_id and organization_id = p_organization_id and case_public_id = p_case_public_id;
 if found then
   if v_event.metadata->>'actionKind' <> p_action or v_event.metadata->>'emailTo' <> p_to or v_event.communication_subject <> p_subject or v_event.communication_body_snapshot <> p_body or coalesce((v_event.metadata->>'amount')::integer,0) <> coalesce(p_amount,0) then raise exception 'O conteúdo difere da tentativa original'; end if;
   if v_event.metadata->>'sendStatus' = 'sent' then return 'sent'; end if;
   if v_event.metadata->>'sendStatus' <> 'pending' then raise exception 'Tentativa encerrada'; end if;
   if v_event.created_at < now() - interval '23 hours' then raise exception 'A tentativa requer conferência manual do envio'; end if;
   return 'pending';
 end if;
 select * into v_settlement from public.case_settlements where organization_id = p_organization_id and case_public_id = p_case_public_id for update;
 if p_action = 'negotiation' and (p_amount is null or p_amount <= 0) then raise exception 'Informe o valor da proposta'; end if;
 if p_action = 'negotiation' and v_settlement.id is not null and v_settlement.status not in ('draft','proposal_sent','cancelled') then raise exception 'O acordo já avançou além da proposta'; end if;
 if p_action = 'collections' and (v_settlement.id is null or v_settlement.status not in ('sra_signed','payment_pending','overdue','collections')) then raise exception 'Não há acordo pendente para cobrança'; end if;
 insert into public.case_events (id, organization_id, case_public_id, workflow_id, detection_id, user_id, event_kind, direction, title, notes, communication_subject, communication_body_snapshot, metadata)
 values (p_id, p_organization_id, p_case_public_id, v_workflow.id, p_detection_id, auth.uid(), case when p_action = 'negotiation' then 'negotiation' else 'payment' end,
 'outbound', 'Envio em andamento', nullif(trim(p_notes),''), p_subject, p_body, jsonb_build_object('actionKind',p_action,'emailTo',p_to,'amount',p_amount,'sendStatus','pending'));
 return 'pending';
end $$;
revoke all on function public.reserve_case_financial_communication(uuid,uuid,integer,uuid,text,text,text,text,text,integer) from public, anon;
grant execute on function public.reserve_case_financial_communication(uuid,uuid,integer,uuid,text,text,text,text,text,integer) to authenticated;

create or replace function public.finalize_case_financial_communication(p_id uuid, p_organization_id uuid, p_case_public_id integer)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_event public.case_events%rowtype; v_action text; v_amount integer; v_workflow_id uuid;
begin
 if auth.uid() is null or not public.is_admin_user() or not exists (select 1 from public.profiles where id = auth.uid() and is_active) then raise exception 'Acesso negado'; end if;
 select * into v_event from public.case_events where id = p_id and organization_id = p_organization_id and case_public_id = p_case_public_id for update;
 if not found then raise exception 'Comunicação não encontrada'; end if;
 if v_event.metadata->>'sendStatus' = 'sent' then return; end if;
 v_action := v_event.metadata->>'actionKind'; v_amount := (v_event.metadata->>'amount')::integer;
 if v_event.metadata->>'sendStatus' <> 'pending' or v_action not in ('negotiation','collections') then raise exception 'Comunicação inválida'; end if;
 insert into public.case_workflows (organization_id,case_public_id,representative_detection_id,stage,created_by_user_id,updated_by_user_id)
 values (p_organization_id,p_case_public_id,v_event.detection_id,case when v_action='negotiation' then 'negotiation' else 'collections' end,auth.uid(),auth.uid())
 on conflict (organization_id,case_public_id) do update set stage=excluded.stage,updated_by_user_id=auth.uid()
 where public.case_workflows.stage <> 'closed' returning id into v_workflow_id;
 if v_workflow_id is null then raise exception 'Caso encerrado'; end if;
 if v_action = 'negotiation' then
   insert into public.case_settlements (organization_id, case_public_id, workflow_id, status, proposed_amount_cents, proposal_sent_at, created_by_user_id, updated_by_user_id)
   values (p_organization_id,p_case_public_id,v_workflow_id,'proposal_sent',v_amount,now(),auth.uid(),auth.uid())
   on conflict (organization_id,case_public_id) do update set status='proposal_sent', proposed_amount_cents=excluded.proposed_amount_cents, proposal_sent_at=now(), updated_by_user_id=auth.uid();
 else
   update public.case_settlements set status='collections',collections_started_at=now(),updated_by_user_id=auth.uid()
   where organization_id=p_organization_id and case_public_id=p_case_public_id and status in ('sra_signed','payment_pending','overdue','collections');
   if not found then raise exception 'Acordo não está pendente'; end if;
 end if;
 update public.case_events set workflow_id=v_workflow_id, title=case when v_action='negotiation' then 'Negociação / proposta' else 'Inadimplência / cobrança' end,
 metadata=metadata || jsonb_build_object('sendStatus','sent') where id=p_id and organization_id=p_organization_id;
end $$;
revoke all on function public.finalize_case_financial_communication(uuid,uuid,integer) from public, anon;
grant execute on function public.finalize_case_financial_communication(uuid,uuid,integer) to authenticated;

create or replace function public.resolve_case_financial_communication(p_id uuid, p_organization_id uuid, p_case_public_id integer, p_resolution text)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_event public.case_events%rowtype;
begin
 if auth.uid() is null or not public.is_admin_user() or not exists (select 1 from public.profiles where id=auth.uid() and is_active) then raise exception 'Acesso negado'; end if;
 if p_resolution not in ('sent','not_sent') then raise exception 'Resolução inválida'; end if;
 select * into v_event from public.case_events where id=p_id and organization_id=p_organization_id and case_public_id=p_case_public_id for update;
 if not found or v_event.metadata->>'sendStatus' <> 'pending' then raise exception 'Envio pendente não encontrado'; end if;
 if p_resolution='sent' then
   perform public.finalize_case_financial_communication(p_id,p_organization_id,p_case_public_id);
 else
   update public.case_events set title='Envio não realizado', metadata=metadata || jsonb_build_object('sendStatus','cancelled') where id=p_id and organization_id=p_organization_id;
 end if;
 insert into public.case_events (organization_id,case_public_id,workflow_id,detection_id,user_id,event_kind,direction,title,notes,metadata)
 values (p_organization_id,p_case_public_id,coalesce(v_event.workflow_id, (select id from public.case_workflows where organization_id=p_organization_id and case_public_id=p_case_public_id)),v_event.detection_id,auth.uid(),'note','internal','Conferência de envio',
   case when p_resolution='sent' then 'A equipe confirmou que a mensagem foi enviada.' else 'A equipe confirmou que a mensagem não foi enviada.' end,
   jsonb_build_object('communicationId',p_id,'resolution',p_resolution));
end $$;
revoke all on function public.resolve_case_financial_communication(uuid,uuid,integer,text) from public, anon;
grant execute on function public.resolve_case_financial_communication(uuid,uuid,integer,text) to authenticated;
commit;
