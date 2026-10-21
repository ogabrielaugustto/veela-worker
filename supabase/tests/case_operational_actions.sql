begin;
insert into auth.users(id,email) values ('00000000-0000-4000-8000-000000000001','admin-test@example.com'),('00000000-0000-4000-8000-000000000002','user-test@example.com');
set local session_replication_role = replica;
update public.profiles set system_role='admin' where id='00000000-0000-4000-8000-000000000001';
set local session_replication_role = origin;
insert into public.organizations(id,name) values ('10000000-0000-4000-8000-000000000001','Org A'),('10000000-0000-4000-8000-000000000002','Org B');
insert into public.assets(id,organization_id,title) values ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','Imagem A'),('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','Imagem B');
insert into public.detections(id,organization_id,asset_id,source_url,canonical_source_url,domain,status,case_public_id) values
('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','https://example.com/a','https://example.com/a','example.com','unauthorized',123456),
('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','https://example.org/a','https://example.org/a','example.org','unauthorized',123456);
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000002',123456,'30000000-0000-4000-8000-000000000002','negotiation','to@example.com','Proposta','Conteúdo da proposta',null,10000);
do $$ begin
 if exists(select 1 from public.case_workflows where organization_id='10000000-0000-4000-8000-000000000002' and case_public_id=123456) then raise exception 'Etapa alterada antes do envio'; end if;
end $$;
select public.resolve_case_financial_communication('40000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000002',123456,'not_sent');
select public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','internal_note','Nota',null,null,null,null);
select public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','negotiation','to@example.com','Proposta','Conteúdo da proposta',null,10000);
select public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','negotiation','to@example.com','Proposta','Conteúdo da proposta',null,10000);
do $$ begin
  begin
    perform public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','close_resolved','Caso resolvido',null,null,null,null);
    raise exception 'Ação com envio pendente foi permitida';
  exception when raise_exception then if sqlerrm='Ação com envio pendente foi permitida' then raise; end if; end;
  begin
    perform public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','negotiation','to@example.com','Proposta','Mensagem alterada',null,10000);
    raise exception 'Tentativa alterada foi permitida';
  exception when raise_exception then if sqlerrm='Tentativa alterada foi permitida' then raise; end if; end;
end $$;
select public.finalize_case_financial_communication('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',123456);
select public.finalize_case_financial_communication('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',123456);
reset role;
insert into public.case_documents(organization_id,case_public_id,document_kind,status,title) values ('10000000-0000-4000-8000-000000000001',123456,'sra','signed','SRA');
update public.case_settlements set status='payment_pending',payment_reference='preservar' where organization_id='10000000-0000-4000-8000-000000000001' and case_public_id=123456;
set local role authenticated;
select public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','collections','to@example.com','Cobrança','Mensagem de cobrança',null,null);
select public.finalize_case_financial_communication('40000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',123456);
select public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','collections','to@example.com','Cobrança 2','Mensagem de cobrança',null,null);
select public.resolve_case_financial_communication('40000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001',123456,'not_sent');
do $$ begin
 begin
   perform public.reserve_case_financial_communication('40000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','collections','to@example.com','Cobrança 2','Mensagem de cobrança',null,null);
   raise exception 'Tentativa cancelada reaberta';
 exception when raise_exception then if sqlerrm='Tentativa cancelada reaberta' then raise; end if; end;
end $$;
do $$ begin
  begin
    perform public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','close_resolved',' ',null,null,null,null);
    raise exception 'Fechamento sem justificativa foi permitido';
  exception when raise_exception then if sqlerrm='Fechamento sem justificativa foi permitido' then raise; end if; end;
  begin
    perform public.execute_case_operational_action('10000000-0000-4000-8000-000000000002',123456,'30000000-0000-4000-8000-000000000001','internal_note','Teste',null,null,null,null);
    raise exception 'Detecção de outra organização foi aceita';
  exception when raise_exception then if sqlerrm='Detecção de outra organização foi aceita' then raise; end if; end;
end $$;
do $$ begin
  begin
    perform public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','register_payment','',9999,'2026-10-21','pix',null);
    raise exception 'Pagamento parcial não foi rejeitado';
  exception when raise_exception then if sqlerrm='Pagamento parcial não foi rejeitado' then raise; end if; end;
end $$;
select public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','register_payment','',10000,'2026-10-21','pix','recibo');
select public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','close_resolved','Acordo cumprido',null,null,null,null);
reset role;
do $$ begin
 if not exists(select 1 from public.case_settlements where organization_id='10000000-0000-4000-8000-000000000001' and status='paid' and proposed_amount_cents=10000 and paid_amount_cents=10000) then raise exception 'Pagamento incorreto'; end if;
 if (select status from public.detections where id='30000000-0000-4000-8000-000000000001') <> 'resolved' then raise exception 'Caso não encerrado'; end if;
 if (select status from public.detections where id='30000000-0000-4000-8000-000000000002') <> 'unauthorized' then raise exception 'Outro tenant foi alterado'; end if;
 if (select count(*) from public.case_events where organization_id='10000000-0000-4000-8000-000000000001' and metadata->>'actionKind'='negotiation') <> 1 then raise exception 'Comunicação duplicada'; end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
set local role authenticated;
do $$ begin
 begin
  perform public.execute_case_operational_action('10000000-0000-4000-8000-000000000001',123456,'30000000-0000-4000-8000-000000000001','internal_note','Acesso',null,null,null,null);
  raise exception 'Acesso indevido permitido';
 exception when raise_exception then if sqlerrm='Acesso indevido permitido' then raise; end if; end;
end $$;
rollback;
