-- Pin the trigger function's search_path (security linter 0011).
alter function public.contacts_set_updated_at() set search_path = '';
