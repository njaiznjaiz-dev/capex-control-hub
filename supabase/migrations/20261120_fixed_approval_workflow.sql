-- CAPEX Control Hub: fixed four-stage approval workflow
-- Run once in the existing CAPEX Supabase project's SQL Editor.
-- Order: Department Head submission -> Hotel GM -> Group Finance -> Group Approver/Ownership.
-- No amount thresholds. Every request follows the same route.
begin;

create unique index if not exists approvals_one_step_per_request
on public.approvals (request_id, step_order);

create or replace function public.submit_capex_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_request public.capex_requests%rowtype;
  v_role text;
begin
  select * into v_request from public.capex_requests where id=p_request_id for update;
  if not found then raise exception 'CAPEX request not found'; end if;
  select p.global_role into v_role from public.profiles p
    where p.user_id=auth.uid() and p.active and p.organisation_id=v_request.organisation_id;
  if v_role is null or not public.can_access_hotel(v_request.hotel_id)
     or v_request.status <> 'draft' then
    raise exception 'Request is not eligible for submission';
  end if;
  -- Submission must be by a Department Head for the hotel, or Group Admin acting in that capacity.
  if not (v_role='group_admin' or exists (
    select 1 from public.hotel_memberships hm
    where hm.user_id=auth.uid() and hm.hotel_id=v_request.hotel_id
      and hm.hotel_role='department_head'
  )) then raise exception 'Only a Department Head may submit CAPEX requests'; end if;
  if v_request.requested_by <> auth.uid() and v_role <> 'group_admin' then
    raise exception 'You may only submit your own draft'; end if;
  update public.capex_requests set status='submitted', submitted_at=now(), updated_at=now()
    where id=p_request_id;
  insert into public.approvals (organisation_id,hotel_id,request_id,step_order,approver_role,decision)
  values
    (v_request.organisation_id,v_request.hotel_id,p_request_id,1,'general_manager','pending'),
    (v_request.organisation_id,v_request.hotel_id,p_request_id,2,'group_finance','pending'),
    (v_request.organisation_id,v_request.hotel_id,p_request_id,3,'group_approver','pending');
  insert into public.audit_events
    (organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
  values (v_request.organisation_id,v_request.hotel_id,auth.uid(),'capex_request',p_request_id,'submitted',
    jsonb_build_object('approval_path','hotel_gm > group_finance > group_approver'));
end $$;

create or replace function public.decide_capex_request(
  p_request_id uuid, p_decision text, p_comment text default null
) returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_request public.capex_requests%rowtype;
  v_step public.approvals%rowtype;
  v_role text;
  v_authorised boolean := false;
  v_hotel_code text;
  v_project_number text;
begin
  if p_decision not in ('approved','rejected','returned') then
    raise exception 'Invalid decision'; end if;
  if p_decision <> 'approved' and nullif(btrim(p_comment),'') is null then
    raise exception 'A reason is required for rejection or return'; end if;
  select * into v_request from public.capex_requests where id=p_request_id for update;
  if not found or v_request.status not in ('submitted','in_review') then
    raise exception 'Request is not awaiting approval'; end if;
  select p.global_role into v_role from public.profiles p
    where p.user_id=auth.uid() and p.active and p.organisation_id=v_request.organisation_id;
  if v_role is null then raise exception 'Active organisation profile required'; end if;
  select * into v_step from public.approvals
    where request_id=p_request_id and decision='pending'
    order by step_order limit 1 for update;
  if not found then raise exception 'No pending approval step'; end if;
  if v_step.approver_role='general_manager' then
    select exists(select 1 from public.hotel_memberships hm
      where hm.hotel_id=v_request.hotel_id and hm.user_id=auth.uid()
      and hm.hotel_role='general_manager') into v_authorised;
  elsif v_step.approver_role='group_finance' then
    v_authorised := v_role='group_finance';
  elsif v_step.approver_role='group_approver' then
    v_authorised := v_role='group_approver';
  end if;
  if not v_authorised then raise exception 'You are not authorised for this approval step'; end if;
  if v_request.requested_by=auth.uid() then
    raise exception 'Requesters cannot approve their own requests'; end if;
  update public.approvals set decision=p_decision::public.approval_decision,
    approver_user_id=auth.uid(), comments=nullif(btrim(p_comment),''),
    decided_at=now() where id=v_step.id;
  insert into public.audit_events
    (organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
  values (v_request.organisation_id,v_request.hotel_id,auth.uid(),'capex_request',
    p_request_id,'approval_'||p_decision,
    jsonb_build_object('step',v_step.step_order,'role',v_step.approver_role,'comment',p_comment));
  if p_decision='rejected' then
    update public.capex_requests set status='rejected',decided_at=now(),updated_at=now()
      where id=p_request_id;
    return 'rejected';
  elsif p_decision='returned' then
    -- Keep returned requests out of active approval queues; requester may create a new draft.
    update public.capex_requests set status='rejected',decided_at=now(),updated_at=now()
      where id=p_request_id;
    return 'returned';
  elsif v_step.step_order < 3 then
    update public.capex_requests set status='in_review',updated_at=now() where id=p_request_id;
    return 'in_review';
  else
    select code into v_hotel_code from public.hotels
      where id=v_request.hotel_id and organisation_id=v_request.organisation_id;
    -- UUID-derived number avoids concurrency races and is unique within a hotel.
    v_project_number := v_hotel_code || '-CAP-' || upper(replace(v_request.id::text,'-',''));
    update public.capex_requests set status='approved',decided_at=now(),updated_at=now()
      where id=p_request_id;
    insert into public.projects (organisation_id,hotel_id,request_id,project_number,
      title,approved_budget,currency,target_completion_date)
    values (v_request.organisation_id,v_request.hotel_id,p_request_id,v_project_number,
      v_request.title,v_request.estimated_amount,v_request.currency,v_request.target_completion_date);
    insert into public.audit_events
      (organisation_id,hotel_id,actor_user_id,entity_type,entity_id,action,after_data)
    values (v_request.organisation_id,v_request.hotel_id,auth.uid(),'capex_request',
      p_request_id,'project_created',jsonb_build_object('project_number',v_project_number));
    return v_project_number;
  end if;
end $$;

revoke all on function public.submit_capex_request(uuid) from public, anon;
revoke all on function public.decide_capex_request(uuid,text,text) from public, anon;
grant execute on function public.submit_capex_request(uuid) to authenticated;
grant execute on function public.decide_capex_request(uuid,text,text) to authenticated;

commit;
