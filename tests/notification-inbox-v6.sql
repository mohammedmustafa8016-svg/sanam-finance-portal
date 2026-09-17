-- Execute inside BEGIN/ROLLBACK. Never leave test notifications in production.
do $$
declare owner uuid; other_user uuid; first_id uuid; old_id uuid; d jsonb; before_count int; before_unread int; history_count int; cycle_start timestamptz;
begin
 select id into owner from public.profiles where active and role='CFO' limit 1;
 select id into other_user from public.profiles where active and role='Supervisor' limit 1;
 select started_at into cycle_start from private.workcenter_cycles where active;
 perform set_config('request.jwt.claim.sub',owner::text,true);
 d:=public.get_notification_inbox_v6();before_count:=(d->>'total')::int;before_unread:=(d->>'unread')::int;
 d:=public.get_notification_inbox_v6('history');history_count:=(d->>'total')::int;
 insert into public.task_notifications(user_id,notification_type,title,created_at) select owner,'TASK_COMMENT','INBOX_ROLLBACK',now()+i*interval '1 microsecond' from generate_series(1,65) i;
 select id into first_id from public.task_notifications where user_id=owner and title='INBOX_ROLLBACK' order by created_at desc limit 1;
 insert into public.task_notifications(user_id,notification_type,title,created_at) values(owner,'TASK_COMMENT','OLD_INBOX_ROLLBACK',cycle_start-interval '1 second') returning id into old_id;
 d:=public.get_notification_inbox_v6('current',false,30,0);
 if (d->>'total')::int<>before_count+65 or (d->>'unread')::int<>before_unread+65 or jsonb_array_length(d->'items')<>30 then raise exception 'INBOX_COUNT_OR_PAGE'; end if;
 d:=public.get_notification_inbox_v6('current',false,30,30);
 if jsonb_array_length(d->'items')<>30 then raise exception 'SECOND_PAGE'; end if;
 d:=public.get_notification_inbox_v6('history');if (d->>'total')::int<>history_count+1 then raise exception 'HISTORY_SCOPE'; end if;
 perform set_config('request.jwt.claim.sub',other_user::text,true);
 perform public.mark_task_notification_read(first_id);
 if exists(select 1 from public.task_notifications where id=first_id and read_at is not null) then raise exception 'OTHER_RECIPIENT_MARKED'; end if;
 d:=public.get_notification_inbox_v6('current',false,100,0);
 if exists(select 1 from jsonb_array_elements(d->'items') x where x->>'title'='INBOX_ROLLBACK') then raise exception 'RECIPIENT_LEAK'; end if;
 perform set_config('request.jwt.claim.sub',owner::text,true);
 perform public.mark_task_notification_read(first_id);
 d:=public.get_notification_inbox_v6('current',true,100,0);
 if (d->>'unread')::int<>before_unread+64 then raise exception 'READ_STATE'; end if;
 if has_function_privilege('anon','public.get_notification_inbox_v6(text,boolean,integer,integer)','EXECUTE') then raise exception 'ANON_GRANT'; end if;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.get_notification_inbox_v6();raise exception 'ANON_ACCESS'; exception when others then if sqlerrm<>'NOT_AUTHORIZED' then raise; end if;end;
end $$;
select 'PASS: full unread count, pagination beyond 50, current/history split, recipient isolation, mark-read ownership, anonymous denial' as result;

