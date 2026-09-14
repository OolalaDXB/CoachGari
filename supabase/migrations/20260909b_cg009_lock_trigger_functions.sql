-- CG-009 hardening: the CRM link trigger functions only ever run as triggers
-- (as the table owner). They should not be callable as RPCs by anyone.
revoke execute on function public.contacts_link_crm() from public, anon, authenticated;
revoke execute on function public.bookings_link_crm() from public, anon, authenticated;
