-- Removing a mailbox failed with a foreign-key violation whenever it had ever
-- sent: tasks.email_account_id and warmup_admin_actions.email_account_id
-- referenced email_accounts without ON DELETE CASCADE, unlike every other
-- mailbox-scoped FK. Both columns are NOT NULL, so SET NULL is not available.

ALTER TABLE public.tasks
    DROP CONSTRAINT IF EXISTS tasks_email_account_id_fkey;

ALTER TABLE public.tasks
    ADD CONSTRAINT tasks_email_account_id_fkey
    FOREIGN KEY (email_account_id) REFERENCES public.email_accounts (id) ON DELETE CASCADE;

ALTER TABLE public.warmup_admin_actions
    DROP CONSTRAINT IF EXISTS warmup_admin_actions_email_account_id_fkey;

ALTER TABLE public.warmup_admin_actions
    ADD CONSTRAINT warmup_admin_actions_email_account_id_fkey
    FOREIGN KEY (email_account_id) REFERENCES public.email_accounts (id) ON DELETE CASCADE;
