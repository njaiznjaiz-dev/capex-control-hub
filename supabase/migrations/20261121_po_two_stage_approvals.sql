-- CAPEX Control Hub: Hotel GM -> Group Finance purchase order workflow
-- Review in Supabase SQL Editor before running. Applies to existing public tables.
-- The migration does not change existing CAPEX request approvals.
begin;

create table if not exists public.po_approval_steps (
 id uuid primary key default gen_random_uuid(),
 organisation_id uuid not null references public.organisations(id),
 hotel_id uuid not null references public.hotels(id),
 purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
 step_order integer not null check (step_order in (1,2)),
 approver_role text not null check (approver_role in ('general_manager','group_finance')),
 decision text not null default 'pending' check (decision in ('pending','approved','rejected')),
 approver_user_id uuid references public.profiles(user_id),
 comments text,
 decided_at timestamptz,
 created_at timestamptz not null default now(),
 unique (purchase_order_id,step_order)
);
create index if not exists po_approval_steps_pending_idx on public.po_approval_steps(purchase_order_id,decision,step_order);
alter table public.po_approval_steps enable row level security;
-- Only authorised RPCs write approval steps. No client DML grants.
revoke all on public.po_approval_steps from anon,authenticated;
grant select on public.po_approval_steps to authenticated;
drop policy if exists po_approval_steps_read on public.po_approval_steps;
create policy po_approval_steps_read on public.po_approval_steps for select to authenticated
 using (exists(select 1 from public.profiles p where p.user_id=(select auth.uid())
 and p.organisation_id=po_approval_steps.organisation_id and p.active=true)
 and public.can_access_hotel(po_approval_steps.hotel_id));

-- Protect PO writes from direct client modifications; RPCs run as their owner.
revoke insert,update,delete on public.purchase_orders from anon,authenticated;

create or replace function public.create_po_draft(
 p_project_id uuid,p_supplier_id uuid,p_description text,p_amount numeric
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_project public.projects%rowtype; v_supplier public.suppliers%rowtype;
 v_role text; v_id uuid; v_number text; v_user uuid:=auth.uid();
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_project from public.projects where id=p_project_id;
 if not found then raise exception 'Project not found'; end if;
 if not exists(select 1 from public.capex_requests r where r.id=v_project.request_id and r.status='approved')
 then raise exception 'Project CAPEX request must be approved'; end if;
 select global_role into v_role from public.profiles
 where user_id=v_user and organisation_id=v_project.organisation_id and active=true;
 if v_role is null or not public.can_access_hotel(v_project.hotel_id)
 then raise exception 'Access denied'; end if;
 if not (v_role in ('group_admin','group_finance') or exists(
 select 1 from public.hotel_memberships m where m.user_id=v_user
 and m.hotel_id=v_project.hotel_id and m.hotel_role in ('department_head','general_manager')))
 then raise exception 'Not authorised to raise purchase orders'; end if;
 select * into v_supplier from public.suppliers
 where id=p_supplier_id and organisation_id=v_project.organisation_id and active=true;
 if not found then raise exception 'Active supplier not found in this organisation'; end if;
 if nullif(btrim(p_description),'') is null or p_amount is null or p_amount<=0
 then raise exception 'Description and positive amount are required'; end if;
 if v_project.status in ('completed','cancelled') then raise exception 'Project is closed'; end if;
 v_id:=gen_random_uuid();
 v_number:='PO-'||upper(substr(replace(v_id::text,'-',''),1,16));
 insert into public.purchase_orders( id,organisation_id,hotel_id,project_id,supplier_id,
 po_number,description,amount,currency,status,raised_by)
 values(v_id,v_project.organisation_id,v_project.hotel_id,v_project.id,v_supplier.id,
 v_number,btrim(p_description),p_amount,v_project.currency,'draft',v_user);
 insert into public.audit_events(organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
 values(v_project.organisation_id,v_project.hotel_id,v_user,'purchase_order',v_id,'po_created',
 jsonb_build_object('project_id',p_project_id,'amount',p_amount,'po_number',v_number));
 return v_id;
end $$;

create or replace function public.submit_purchase_order(p_po_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_po public.purchase_orders%rowtype; v_budget numeric; v_committed numeric; v_role text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into v_po from public.purchase_orders where id=p_po_id for update;
 if not found or v_po.status<>'draft' then raise exception 'PO is not a draft'; end if;
 select global_role into v_role from public.profiles where user_id=auth.uid()
 and organisation_id=v_po.organisation_id and active=true;
 if v_role is null or not public.can_access_hotel(v_po.hotel_id) then raise exception 'Access denied'; end if;
 if v_po.raised_by<>auth.uid() and v_role<>'group_admin' then raise exception 'Only PO creator or group admin may submit'; end if;
 -- Lock project to serialize submissions and approvals against the same budget.
 select approved_budget into v_budget from public.projects
 where id=v_po.project_id and organisation_id=v_po.organisation_id and hotel_id=v_po.hotel_id for update;
 if not found then raise exception 'Project mismatch'; end if;
 select coalesce(sum(amount),0) into v_committed from public.purchase_orders
 where project_id=v_po.project_id and id<>v_po.id
 and status in ('pending_approval','approved','issued','partially_received','closed');
 if v_committed+v_po.amount>v_budget then raise exception 'PO exceeds remaining approved project budget'; end if;
 insert into public.po_approval_steps(organisation_id,hotel_id,purchase_order_id,step_order,approver_role)
 values(v_po.organisation_id,v_po.hotel_id,p_po_id,1,'general_manager'),
 (v_po.organisation_id,v_po.hotel_id,p_po_id,2,'group_finance');
 update public.purchase_orders set status='pending_approval',updated_at=now() where id=p_po_id;
 insert into public.audit_events(organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
 values(v_po.organisation_id,v_po.hotel_id,auth.uid(),'purchase_order',p_po_id,'po_submitted',
 jsonb_build_object('amount',v_po.amount));
end $$;

create or replace function public.decide_purchase_order(p_po_id uuid,p_decision text,p_comment text default null)
returns text language plpgsql security definer set search_path=''
as $$
declare v_po public.purchase_orders%rowtype; v_step public.po_approval_steps%rowtype;
 v_role text; v_budget numeric; v_committed numeric; v_authorised boolean:=false;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'Invalid decision'; end if;
 if p_decision='rejected' and nullif(btrim(p_comment),'') is null then raise exception 'Rejection reason required'; end if;
 select * into v_po from public.purchase_orders where id=p_po_id for update;
 if not found or v_po.status<>'pending_approval' then raise exception 'PO not awaiting approval'; end if;
 select global_role into v_role from public.profiles where user_id=auth.uid()
 and organisation_id=v_po.organisation_id and active=true;
 if v_role is null or not public.can_access_hotel(v_po.hotel_id) then raise exception 'Access denied'; end if;
 if v_po.raised_by=auth.uid() then raise exception 'PO creator cannot approve their own PO'; end if;
 select * into v_step from public.po_approval_steps where purchase_order_id=p_po_id
 and decision='pending' order by step_order limit 1 for update;
 if not found then raise exception 'No pending PO approval step'; end if;
 if v_step.approver_role='general_manager' then
 select exists(select 1 from public.hotel_memberships m where m.user_id=auth.uid()
 and m.hotel_id=v_po.hotel_id and m.hotel_role='general_manager') into v_authorised;
 elsif v_step.approver_role='group_finance' then v_authorised:=(v_role='group_finance');
 end if;
 if not v_authorised then raise exception 'Not authorised for this approval stage'; end if;
 if p_decision='approved' then
 select approved_budget into v_budget from public.projects
 where id=v_po.project_id and organisation_id=v_po.organisation_id and hotel_id=v_po.hotel_id for update;
 select coalesce(sum(amount),0) into v_committed from public.purchase_orders
 where project_id=v_po.project_id and id<>v_po.id
 and status in ('pending_approval','approved','issued','partially_received','closed');
 if v_budget is null or v_committed+v_po.amount>v_budget
 then raise exception 'Approval would exceed approved project budget'; end if;
 end if;
 update public.po_approval_steps set decision=p_decision,approver_user_id=auth.uid(),
 comments=nullif(btrim(p_comment),''),decided_at=now() where id=v_step.id;
 insert into public.audit_events(organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
 values(v_po.organisation_id,v_po.hotel_id,auth.uid(),'purchase_order',p_po_id,'po_approval_'||p_decision,
 jsonb_build_object('step',v_step.step_order,'role',v_step.approver_role,'comment',p_comment));
 if p_decision='rejected' then
 update public.purchase_orders set status='cancelled',updated_at=now() where id=p_po_id;
 return 'cancelled';
 end if;
 if v_step.step_order=1 then return 'pending_approval'; end if;
 update public.purchase_orders set status='approved',approved_by=auth.uid(),updated_at=now() where id=p_po_id;
 return 'approved';
end $$;

create or replace function public.issue_purchase_order(p_po_id uuid)
returns text language plpgsql security definer set search_path=''
as $$
declare v_po public.purchase_orders%rowtype; v_role text; v_budget numeric; v_committed numeric;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into v_po from public.purchase_orders where id=p_po_id for update;
 if not found or v_po.status<>'approved' then raise exception 'PO must be fully approved before issue'; end if;
 select global_role into v_role from public.profiles where user_id=auth.uid()
 and organisation_id=v_po.organisation_id and active=true;
 if v_role not in ('group_finance','group_admin') or not public.can_access_hotel(v_po.hotel_id)
 then raise exception 'Only authorised Group Finance or Group Admin may issue POs'; end if;
 select approved_budget into v_budget from public.projects where id=v_po.project_id for update;
 select coalesce(sum(amount),0) into v_committed from public.purchase_orders
 where project_id=v_po.project_id and id<>v_po.id
 and status in ('pending_approval','approved','issued','partially_received','closed');
 if v_committed+v_po.amount>v_budget then raise exception 'PO exceeds remaining approved project budget'; end if;
 update public.purchase_orders set status='issued',issued_at=now(),updated_at=now() where id=p_po_id;
 insert into public.audit_events(organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
 values(v_po.organisation_id,v_po.hotel_id,auth.uid(),'purchase_order',p_po_id,'po_issued',
 jsonb_build_object('po_number',v_po.po_number,'amount',v_po.amount));
 return v_po.po_number;
end $$;

revoke all on function public.create_po_draft(uuid,uuid,text,numeric) from public,anon;
revoke all on function public.submit_purchase_order(uuid) from public,anon;
revoke all on function public.decide_purchase_order(uuid,text,text) from public,anon;
revoke all on function public.issue_purchase_order(uuid) from public,anon;
grant execute on function public.create_po_draft(uuid,uuid,text,numeric) to authenticated;
grant execute on function public.submit_purchase_order(uuid) to authenticated;
grant execute on function public.decide_purchase_order(uuid,text,text) to authenticated;
grant execute on function public.issue_purchase_order(uuid) to authenticated;
commit;
