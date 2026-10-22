-- Work Center V3.1 programmable authorization rules.

insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
values
('EMP_ASSIGNED_CLARIFY','Employee','Assigned','REQUEST_CLARIFICATION','*','ASSIGNEE','Waiting','CLARIFICATION_REQUESTED',true,'EVENT_ONLY',25,true,'ALLOW','ANY'),
('EMP_ASSIGNED_COMMENT','Employee','Assigned','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_READY_COMMENT','Employee','Ready','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_PROGRESS_COMMENT','Employee','In Progress','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_BLOCKED_COMMENT','Employee','Blocked','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_EXT_COMMENT','Employee','Extension Requested','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_REVIEW_COMMENT','Employee','Pending Review','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_WAITING_COMMENT','Employee','Waiting','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_REWORK_COMMENT','Employee','Returned for Rework','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY')
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Explicit employee deny rules. CFO/Supervisor exact-role allows outrank inherited Employee denies.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'EMP_DENY_'||a,'Employee','*',a,'*','ACCESS',null,'UNAUTHORIZED_ACTION_ATTEMPT',false,'GENERIC',999,true,'DENY','ANY'
from (values ('REASSIGN'),('CHANGE_REVIEWER'),('CHANGE_DUE'),('CHANGE_PRIORITY'),('APPROVE_COMPLETION'),('RETURN_REWORK'),('REOPEN'),('FORCE_CLOSE'),('STAGE_OVERRIDE'),('CANCEL_MANUAL_TASK')) v(a)
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Supervisor: reassign active/review/rework work only.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'SUP_'||replace(upper(s),' ','_')||'_REASSIGN','Supervisor',s,'REASSIGN','MANUAL_TASK','MANAGER',null,'WORK_REASSIGNED',true,'REASSIGN_TASK',10,true,'ALLOW','TASK'
from unnest(array['Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Supervisor: due-date changes in permitted open states.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'SUP_'||replace(upper(s),' ','_')||'_DUE','Supervisor',s,'CHANGE_DUE','MANUAL_TASK','MANAGER',null,'DUE_CHANGED',true,'CHANGE_TASK',20,true,'ALLOW','TASK'
from unnest(array['Draft','Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Supervisor: priority changes excluding completed/closed items and pending review.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'SUP_'||replace(upper(s),' ','_')||'_PRIORITY','Supervisor',s,'CHANGE_PRIORITY','MANUAL_TASK','MANAGER',null,'PRIORITY_CHANGED',false,'CHANGE_TASK',30,true,'ALLOW','TASK'
from unnest(array['Draft','Assigned','Ready','In Progress','Blocked','Extension Requested','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Supervisor explicit denials defined by the approved matrix.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
values
('SUP_DENY_CHANGE_REVIEWER','Supervisor','*','CHANGE_REVIEWER','*','MANAGER',null,'UNAUTHORIZED_ACTION_ATTEMPT',false,'GENERIC',999,true,'DENY','ANY'),
('SUP_DENY_FORCE_CLOSE','Supervisor','*','FORCE_CLOSE','*','MANAGER',null,'UNAUTHORIZED_ACTION_ATTEMPT',false,'GENERIC',999,true,'DENY','ANY'),
('SUP_DENY_STAGE_OVERRIDE','Supervisor','*','STAGE_OVERRIDE','*','MANAGER',null,'UNAUTHORIZED_ACTION_ATTEMPT',false,'GENERIC',999,true,'DENY','ANY')
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- Justification is exposed on operational task states; resolver additionally requires Blocked, overdue or SLA breach.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'SUP_'||replace(upper(s),' ','_')||'_JUSTIFICATION','Supervisor',s,'REQUEST_JUSTIFICATION','MANUAL_TASK','MANAGER',null,'JUSTIFICATION_REQUESTED',true,'REQUEST_JUSTIFICATION',40,true,'ALLOW','TASK'
from unnest(array['Assigned','Ready','In Progress','Blocked','Extension Requested','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

-- CFO precise management rules.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_REASSIGN','CFO',s,'REASSIGN','MANUAL_TASK','CFO',null,'CFO_WORK_REASSIGNED',true,'REASSIGN_TASK',10,true,'ALLOW','TASK'
from unnest(array['Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_DUE','CFO',s,'CHANGE_DUE','MANUAL_TASK','CFO',null,'CFO_DUE_OVERRIDE',true,'CHANGE_TASK',20,true,'ALLOW','TASK'
from unnest(array['Draft','Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_PRIORITY','CFO',s,'CHANGE_PRIORITY','MANUAL_TASK','CFO',null,'CFO_PRIORITY_OVERRIDE',false,'CHANGE_TASK',30,true,'ALLOW','TASK'
from unnest(array['Draft','Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework','Approved']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_REVIEWER','CFO',s,'CHANGE_REVIEWER','MANUAL_TASK','CFO',null,'REVIEWER_CHANGED',true,'CHANGE_TASK',40,true,'ALLOW','TASK'
from unnest(array['Draft','Assigned','Ready','In Progress','Pending Review']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();
