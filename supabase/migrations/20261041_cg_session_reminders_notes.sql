-- =====================================================================
-- Coach Gari — the day before, and the two gestures after (CG-019)
--
-- Three things a coach does every day, and one the software should do for him.
--
--   1. REMIND. A session 24 hours out sends the client one reminder. Email
--      always (it is the channel they gave when they booked), WhatsApp too when
--      that person has said yes to WhatsApp. One reminder per session, ever:
--      the dedupe key is the session, so a re-run, a manual call or an
--      overlapping window never sends a second one.
--
--   2. MARK. done / no-show already exists as session_set_status; nothing to
--      add here. It is the screen that was missing the button.
--
--   3. WRITE ONE LINE. What we worked on, typed on the session card, landing in
--      the client's history where it belongs. Until now a session note lived on
--      the session (coaching_sessions.note) and the client history lived in
--      crm_notes, and the two never met. session_note_quick writes both and
--      links them: crm_notes gains session_id, so the history says which
--      session a line came from.
--
-- WhatsApp is built as a sibling of the email outbox, not as a special case:
-- its own table, its own queue function, its own drain key in Vault, the same
-- dedupe discipline. It is INERT until the owner connects a number — no token,
-- no phone id, and every queued row is marked skipped with a reason instead of
-- piling up. Business-initiated WhatsApp requires a template approved by Meta,
-- so a row carries a template name and its parameters, never free prose.
--
-- Consent: a WhatsApp message is not an email. crm_contacts gains an explicit
-- opt-in, off by default, recorded with when and by whom. No opt-in, no
-- WhatsApp — the email still goes. Anyone can also turn reminders off entirely.
-- =====================================================================

-- ---------- 1. a note can name its session ----------
alter table public.crm_notes add column if not exists session_id uuid
  references public.coaching_sessions(id) on delete set null;
create index if not exists crm_notes_session_idx on public.crm_notes (session_id) where session_id is not null;
comment on column public.crm_notes.session_id is
  'The session this line is about, when it was written from the session card. Null for a free-standing note.';

-- ---------- 2. how this person may be reached ----------
alter table public.crm_contacts add column if not exists reminders_opt_out boolean not null default false;
alter table public.crm_contacts add column if not exists whatsapp_opt_in    boolean not null default false;
alter table public.crm_contacts add column if not exists whatsapp_opt_in_at timestamptz;
alter table public.crm_contacts add column if not exists whatsapp_opt_in_by text;
comment on column public.crm_contacts.whatsapp_opt_in is
  'This person said yes to WhatsApp. Off by default and never inferred: a phone number on file is not consent to message it.';
comment on column public.crm_contacts.reminders_opt_out is
  'Send this person no session reminder on any channel.';

-- ---------- 3. the new email kind ----------
-- The full list is re-issued because a CHECK cannot be extended in place.
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification',
                  'collab_received','collab_ack','collab_proposal','collab_counter','collab_accepted','collab_payment_ready',
                  'collab_declined','collab_reminder','session_reminder'));

-- ---------- 4. audit areas ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','analytics','whatsapp']));

-- ---------- 5. the WhatsApp outbox ----------
create table if not exists public.whatsapp_events (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('session_reminder')),
  crm_contact_id      uuid references public.crm_contacts(id) on delete set null,
  to_phone            text,                        -- digits only, as crm_normalize_phone produces
  template            text not null,               -- the name approved in the Meta console
  params              jsonb not null default '[]'::jsonb,   -- positional {{1}}, {{2}} … body parameters
  language            text not null default 'en',
  status              text not null default 'pending' check (status in ('pending','sent','skipped','failed')),
  dedupe_key          text,
  provider_message_id text,
  error               text,
  attempts            int  not null default 0,
  next_attempt_at     timestamptz not null default now(),
  last_attempt_at     timestamptz,
  created_at          timestamptz not null default now(),
  sent_at             timestamptz
);
create unique index if not exists whatsapp_events_dedupe_key_key on public.whatsapp_events (dedupe_key) where dedupe_key is not null;
create index if not exists whatsapp_events_pending_idx on public.whatsapp_events (next_attempt_at) where status = 'pending';
create index if not exists whatsapp_events_contact_idx on public.whatsapp_events (crm_contact_id, created_at desc);

alter table public.whatsapp_events enable row level security;
revoke all on public.whatsapp_events from anon, authenticated;
-- The row carries a client's phone number, so reading it is a client-profile act.
grant select on public.whatsapp_events to authenticated;
drop policy if exists whatsapp_events_view on public.whatsapp_events;
create policy whatsapp_events_view on public.whatsapp_events for select to authenticated
  using (public.has_permission('client_profile:view'));

/* Queue one message. Idempotent on dedupe_key, exactly like email_queue: the
   second call with the same key inserts nothing and returns null. A row with no
   usable phone is stored as skipped rather than dropped, so the reason is
   visible instead of the message merely never arriving. */
create or replace function public.whatsapp_queue(p_kind text, p_to text, p_template text, p_params jsonb,
                                                 p_dedupe_key text, p_contact_id uuid default null,
                                                 p_language text default 'en')
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid; v_phone text := public.crm_normalize_phone(p_to);
begin
  insert into public.whatsapp_events (kind, crm_contact_id, to_phone, template, params, language, dedupe_key, status, error)
  values (p_kind, p_contact_id, v_phone, p_template, coalesce(p_params, '[]'::jsonb), coalesce(p_language, 'en'), p_dedupe_key,
          case when v_phone is null then 'skipped' else 'pending' end,
          case when v_phone is null then 'no usable phone number' else null end)
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.whatsapp_queue(text, text, text, jsonb, text, uuid, text) from public, anon, authenticated;
grant  execute on function public.whatsapp_queue(text, text, text, jsonb, text, uuid, text) to service_role;

-- ---------- 6. the drain key: clear in Vault, hashed here ----------
do $$
declare k text;
begin
  if not exists (select 1 from public.outbox_keys where name = 'whatsapp') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_whatsapp_key') then
      perform vault.create_secret(k, 'outbox_whatsapp_key',
        'WhatsApp outbox drain key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    else
      select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_whatsapp_key' limit 1;
    end if;
    insert into public.outbox_keys (name, key_sha256) values ('whatsapp', extensions.digest(k, 'sha256'));
  end if;
end $$;

create or replace function public.whatsapp_outbox_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.outbox_keys k
     where k.name = 'whatsapp'
       and length(coalesce(p_key, '')) = 64
       and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256'))
  )
$$;
revoke execute on function public.whatsapp_outbox_authorize(text) from public, anon, authenticated;
grant  execute on function public.whatsapp_outbox_authorize(text) to service_role;

create or replace function public.whatsapp_outbox_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if not exists (select 1 from public.whatsapp_events where status = 'pending' and next_attempt_at <= now()) then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_whatsapp_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/whatsapp-outbox',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke execute on function public.whatsapp_outbox_kick() from public, anon, authenticated;
grant  execute on function public.whatsapp_outbox_kick() to service_role;

/* The drain reports what it did. Only the function (service_role) calls it.
   A failure goes back to pending twice, five minutes apart, then stops being
   retried: a wrong number or a rejected template will not get better by being
   sent a hundred times, and the error stays on the row to be read. */
create or replace function public.whatsapp_mark(p_id uuid, p_status text, p_provider_id text default null, p_error text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_status not in ('sent','skipped','failed') then raise exception 'bad status' using errcode = '22023'; end if;
  update public.whatsapp_events
     set status = case when p_status = 'failed' and attempts < 2 then 'pending' else p_status end,
         provider_message_id = coalesce(p_provider_id, provider_message_id),
         error = left(p_error, 300),
         attempts = attempts + 1,
         last_attempt_at = now(),
         sent_at = case when p_status = 'sent' then now() else sent_at end,
         next_attempt_at = case when p_status = 'failed' and attempts < 2 then now() + interval '5 minutes' else next_attempt_at end
   where id = p_id;
end $$;
revoke execute on function public.whatsapp_mark(uuid, text, text, text) from public, anon, authenticated;
grant  execute on function public.whatsapp_mark(uuid, text, text, text) to service_role;

/* What the drain reads. Only pending and due, oldest first, capped. */
create or replace function public.whatsapp_due(p_limit int default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb) from (
    select id, to_phone, template, params, language, created_at
      from public.whatsapp_events
     where status = 'pending' and next_attempt_at <= now() and to_phone is not null
     order by created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) x
$$;
revoke execute on function public.whatsapp_due(int) from public, anon, authenticated;
grant  execute on function public.whatsapp_due(int) to service_role;

-- ---------- 7. the reminder ----------
/* Every scheduled session starting within the lead window gets one reminder.
   The window is "between now and now + lead" rather than "exactly 24h out", so
   a missed run catches up on the next one instead of skipping a client, and the
   dedupe key makes the overlap free. A session moved out of the window and back
   is still one reminder — which is the point: the client hears once. */
create or replace function public.session_reminders(p_lead interval default interval '24 hours')
returns int language plpgsql volatile security definer set search_path = '' as $$
declare r record; n int := 0; v_key text; v_where text; v_payload jsonb;
begin
  for r in
    select s.id, s.start_at, s.session_timezone, s.delivery_mode, s.location_name, s.location_address, s.meeting_url,
           coalesce(sv.title, s.title, 'Your session') as service_title,
           coalesce(sv.duration_minutes, (extract(epoch from (s.end_at - s.start_at)) / 60)::int) as duration_minutes,
           c.id as contact_id, c.display_name, c.email, c.phone_norm,
           c.reminders_opt_out, c.whatsapp_opt_in,
           coalesce(b.reference, '') as reference
      from public.coaching_sessions s
      join public.crm_contacts c on c.id = s.crm_contact_id
      left join public.services sv on sv.id = s.service_id
      left join public.bookings b on b.id = s.booking_id
     where s.status = 'scheduled'
       and s.start_at > now()
       and s.start_at <= now() + coalesce(p_lead, interval '24 hours')
       and not c.reminders_opt_out
  loop
    v_key := 'session:' || r.id || ':reminder';
    v_where := case when r.delivery_mode = 'online' then coalesce(nullif(r.meeting_url, ''), 'Online')
                    else coalesce(nullif(r.location_name, ''), nullif(r.location_address, ''), 'As agreed') end;
    v_payload := jsonb_build_object(
      'name', coalesce(r.display_name, ''), 'service_title', r.service_title,
      'start_at', r.start_at, 'timezone', r.session_timezone,
      'duration_minutes', r.duration_minutes, 'where', v_where, 'reference', r.reference);

    if r.email is not null then
      if public.email_queue('session_reminder', r.email, v_payload, v_key || ':email', null, null, null) is not null then
        n := n + 1;
      end if;
    end if;

    -- WhatsApp only where this person has said yes. Template parameters, in order:
    -- {{1}} first name · {{2}} what · {{3}} when, in their session's timezone.
    if r.whatsapp_opt_in and r.phone_norm is not null then
      if public.whatsapp_queue('session_reminder', r.phone_norm, 'session_reminder_24h',
           jsonb_build_array(
             coalesce(split_part(btrim(r.display_name), ' ', 1), 'there'),
             r.service_title,
             to_char(r.start_at at time zone r.session_timezone, 'Dy DD Mon, HH24:MI')),
           v_key || ':whatsapp', r.contact_id) is not null then
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function public.session_reminders(interval) from public, anon, authenticated;
grant  execute on function public.session_reminders(interval) to service_role;

-- ---------- 8. one line, from the card ----------
/* The daily gesture: what we worked on. It writes the session's own note and a
   line in the client's history, linked to that session, in one audited call.
   Two permissions on purpose — moving a session is scheduling work, writing in
   someone's history is not. A scheduler must not become a note-taker by
   accident. */
create or replace function public.session_note_quick(p_id uuid, p_text text, p_scope text default 'operational')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_contact uuid; v_note uuid; v_body text := btrim(coalesce(p_text, ''));
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_scope not in ('operational','coach_private') then raise exception 'bad scope' using errcode = '22023'; end if;
  if p_scope = 'coach_private' then
    if not public.has_permission('coaching_sensitive:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif not public.has_permission('client_profile:manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_body = '' then raise exception 'empty note' using errcode = '22023'; end if;
  if length(v_body) > 500 then raise exception 'one line, not an essay' using errcode = '22023'; end if;

  select crm_contact_id into v_contact from public.coaching_sessions where id = p_id;
  if v_contact is null then raise exception 'no such session' using errcode = 'P0002'; end if;

  update public.coaching_sessions set note = v_body where id = p_id;

  insert into public.crm_notes (crm_contact_id, session_id, body, category, scope, author)
  values (v_contact, p_id, v_body, 'session', p_scope, coalesce(public.current_email(), 'system'))
  returning id into v_note;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', p_id::text, 'note', coalesce(public.current_email(), 'system'),
          jsonb_build_object('note_id', v_note, 'scope', p_scope, 'length', length(v_body)));

  return jsonb_build_object('ok', true, 'note_id', v_note, 'session_id', p_id);
end $$;
revoke execute on function public.session_note_quick(uuid, text, text) from public, anon;
grant  execute on function public.session_note_quick(uuid, text, text) to authenticated, service_role;

-- ---------- 9. recording the WhatsApp yes ----------
create or replace function public.contact_messaging_set(p_contact_id uuid, p_whatsapp_opt_in boolean default null,
                                                        p_reminders_opt_out boolean default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_email text := coalesce(public.current_email(), 'system');
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;

  update public.crm_contacts
     set whatsapp_opt_in    = coalesce(p_whatsapp_opt_in, whatsapp_opt_in),
         whatsapp_opt_in_at = case when p_whatsapp_opt_in is true and not whatsapp_opt_in then now()
                                   when p_whatsapp_opt_in is false then null else whatsapp_opt_in_at end,
         whatsapp_opt_in_by = case when p_whatsapp_opt_in is true and not whatsapp_opt_in then v_email
                                   when p_whatsapp_opt_in is false then null else whatsapp_opt_in_by end,
         reminders_opt_out  = coalesce(p_reminders_opt_out, reminders_opt_out)
   where id = p_contact_id;
  if not found then raise exception 'no such contact' using errcode = 'P0002'; end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', p_contact_id::text, 'messaging', v_email,
          jsonb_build_object('whatsapp_opt_in', p_whatsapp_opt_in, 'reminders_opt_out', p_reminders_opt_out));

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.contact_messaging_set(uuid, boolean, boolean) from public, anon;
grant  execute on function public.contact_messaging_set(uuid, boolean, boolean) to authenticated, service_role;

-- ---------- 10. the clock ----------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-session-reminders';
    perform cron.schedule('cg-session-reminders', '7 * * * *', $cron$select public.session_reminders()$cron$);
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-whatsapp-outbox';
    perform cron.schedule('cg-whatsapp-outbox', '*/2 * * * *', $cron$select public.whatsapp_outbox_kick()$cron$);
  end if;
end $$;
