// Send-a-test-email dialog for a campaign step.
//
// The API (POST /campaigns/:id/test-email) has existed all along with no way to
// reach it from the dashboard. This is that entry point: pick one of the
// campaign's sender mailboxes, type a recipient, send.
//
// By default the step renders against a synthetic contact (Test Recipient /
// Test Company), so custom merge fields come out empty — surfaced as a warning
// rather than hidden, because a blank {{.subject}} is exactly what recipients
// would get if the import column is missing. Pick a real contact instead and
// the step renders with that contact's fields, which is the honest preview.

import React from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Loader2Icon, SendIcon, XIcon } from "lucide-react";
import toast from "react-hot-toast";
import { Label, TextInput } from "@/components/ui/field";
import useSearchContacts from "@/lib/api/hooks/app/contacts/useSearchContacts";
import useCampaignSenders from "@/lib/api/hooks/app/campaigns/useCampaignSenders";
import useEmails from "@/lib/api/hooks/app/emails/useEmails";
import sendTestEmail from "@/lib/api/client/app/campaigns/sendTestEmail";
import type { AppError } from "@/lib/api/client/normalizeError";
import buildError from "@/lib/helper/buildError";

// Merge fields the synthetic test contact actually provides. Anything else in
// the template renders empty in the test send.
const TEST_CONTACT_FIELDS = ["FirstName", "LastName", "Email", "Company"];

function missingMergeFields(subject: string, body: string): string[] {
    const found = new Set<string>();
    const re = /\{\{\s*\.?([A-Za-z0-9_ -]+)\s*\}\}/g;
    for (const src of [subject, body]) {
        let m: RegExpExecArray | null;
        while ((m = re.exec(src ?? "")) !== null) {
            const name = m[1].trim();
            if (name && !TEST_CONTACT_FIELDS.includes(name)) found.add(name);
        }
    }
    return [...found];
}

export default function SendTestEmailDialog({
    open,
    onClose,
    campaignId,
    stepId,
    subject,
    bodyHtml,
}: {
    open: boolean;
    onClose: () => void;
    campaignId: string;
    stepId: string;
    subject: string;
    bodyHtml: string;
}) {
    const senders = useCampaignSenders(campaignId, open);
    const { emails } = useEmails({ query: "", tag: "", enabled: open });

    const [accountId, setAccountId] = React.useState("");
    const [recipient, setRecipient] = React.useState("");
    const [busy, setBusy] = React.useState(false);
    const [contactQuery, setContactQuery] = React.useState("");
    const [contactId, setContactId] = React.useState<string | null>(null);

    // Render against a real contact so custom merge fields resolve exactly as
    // the live campaign would send them.
    const { contacts: contactResults } = useSearchContacts({
        options: {
            query: contactQuery,
            filters: [],
            campaign_ids: [],
            sort_by: "created_at",
            reverse: true,
        },
        limit: 5,
        enabled: open && contactQuery.trim().length > 1,
        keepPrevious: true,
    });
    const contacts = contactResults ?? [];
    const selectedContact = React.useMemo(
        () => contacts.find((c) => c.id === contactId) ?? null,
        [contacts, contactId],
    );

    // Only the campaign's own senders may send its test.
    const options = React.useMemo(() => {
        const allowed = new Set((senders.data ?? []).filter((s) => s.enabled).map((s) => s.email_account_id));
        return emails.filter((e) => allowed.has(e.id)).map((e) => ({ id: e.id, email: e.email }));
    }, [senders.data, emails]);

    React.useEffect(() => {
        if (open && !accountId && options.length > 0) setAccountId(options[0].id);
    }, [open, accountId, options]);

    const missing = React.useMemo(
        () => (contactId ? [] : missingMergeFields(subject, bodyHtml)),
        [contactId, subject, bodyHtml],
    );
    const canSend = !!accountId && /.+@.+\..+/.test(recipient) && !busy;

    async function submit() {
        if (!canSend) return;
        setBusy(true);
        try {
            await toast.promise(
                sendTestEmail(campaignId, {
                    step_id: stepId,
                    account_id: accountId,
                    recipient,
                    ...(contactId ? { contact_id: contactId } : {}),
                }),
                {
                    loading: "Sending test…",
                    success: `Test sent to ${recipient}`,
                    error: (err: AppError) => buildError(err),
                },
            );
            onClose();
        } finally {
            setBusy(false);
        }
    }

    return (
        <AnimatePresence>
            {open && (
                <motion.div
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    exit={{ opacity: 0 }}
                    className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/30 p-4"
                    onMouseDown={(e) => {
                        if (e.target === e.currentTarget && !busy) onClose();
                    }}
                >
                    <motion.div
                        initial={{ opacity: 0, y: 8, scale: 0.98 }}
                        animate={{ opacity: 1, y: 0, scale: 1 }}
                        exit={{ opacity: 0, y: 8, scale: 0.98 }}
                        transition={{ type: "spring", stiffness: 400, damping: 30 }}
                        className="w-full max-w-md rounded-md border border-slate-200 bg-white shadow-xl"
                    >
                        <div className="flex h-12 shrink-0 items-center justify-between border-b border-slate-200 px-3">
                            <div className="min-w-0">
                                <div className="text-[10px] font-medium uppercase tracking-[0.14em] text-slate-400">
                                    Preview
                                </div>
                                <p className="truncate text-[12.5px] font-medium text-slate-900">Send a test email</p>
                            </div>
                            <button
                                type="button"
                                onClick={onClose}
                                disabled={busy}
                                className="inline-flex h-7 w-7 items-center justify-center rounded-md text-slate-400 transition-colors hover:bg-slate-50 hover:text-slate-700 disabled:opacity-40"
                            >
                                <XIcon className="h-3.5 w-3.5" />
                            </button>
                        </div>

                        <div className="space-y-4 p-3">
                            <div>
                                <Label>Send from</Label>
                                <select
                                    value={accountId}
                                    onChange={(e) => setAccountId(e.target.value)}
                                    disabled={busy || options.length === 0}
                                    className="h-7 w-full rounded-md border border-slate-200 bg-white px-2 text-[12.5px] text-slate-900 transition-colors focus:border-sky-400 focus:outline-none focus:ring-2 focus:ring-sky-100 disabled:opacity-40"
                                >
                                    {options.length === 0 && <option value="">No senders on this campaign</option>}
                                    {options.map((o) => (
                                        <option key={o.id} value={o.id}>
                                            {o.email}
                                        </option>
                                    ))}
                                </select>
                                {options.length === 0 && (
                                    <p className="mt-1.5 text-[10.5px] text-slate-400">
                                        Add a sending mailbox to this campaign first.
                                    </p>
                                )}
                            </div>

                            <div>
                                <Label>Send to</Label>
                                <TextInput
                                    value={recipient}
                                    onChange={setRecipient}
                                    placeholder="you@example.com"
                                    type="email"
                                    disabled={busy}
                                    onKeyDown={(e) => {
                                        if (e.key === "Enter") void submit();
                                    }}
                                />
                                <p className="mt-1.5 text-[10.5px] text-slate-400">
                                    Arrives with a <span className="font-medium text-slate-500">[TEST]</span> subject
                                    prefix. It does not count toward the campaign or the mailbox&apos;s daily cap.
                                </p>
                            </div>

                            <div>
                                <Label>Render as contact (optional)</Label>
                                {selectedContact ? (
                                    <div className="flex items-center justify-between gap-2 rounded-md border border-sky-200 bg-sky-50 px-2 py-1.5">
                                        <div className="min-w-0">
                                            <p className="truncate text-[12px] font-medium text-sky-900">
                                                {selectedContact.first_name} {selectedContact.last_name}
                                            </p>
                                            <p className="truncate text-[10.5px] text-sky-700">
                                                {selectedContact.email}
                                            </p>
                                        </div>
                                        <button
                                            type="button"
                                            onClick={() => {
                                                setContactId(null);
                                                setContactQuery("");
                                            }}
                                            disabled={busy}
                                            className="shrink-0 text-[11px] font-medium text-sky-700 hover:text-sky-900 disabled:opacity-40"
                                        >
                                            Clear
                                        </button>
                                    </div>
                                ) : (
                                    <>
                                        <TextInput
                                            value={contactQuery}
                                            onChange={setContactQuery}
                                            placeholder="Search contacts by name or email"
                                            disabled={busy}
                                        />
                                        {contacts.length > 0 && (
                                            <div className="mt-1 max-h-36 overflow-y-auto rounded-md border border-slate-200">
                                                {contacts.map((c) => (
                                                    <button
                                                        key={c.id}
                                                        type="button"
                                                        onClick={() => setContactId(c.id)}
                                                        className="flex w-full items-center justify-between gap-2 px-2 py-1.5 text-left transition-colors hover:bg-slate-50"
                                                    >
                                                        <span className="truncate text-[12px] text-slate-900">
                                                            {c.first_name} {c.last_name}
                                                        </span>
                                                        <span className="shrink-0 truncate text-[10.5px] text-slate-400">
                                                            {c.email}
                                                        </span>
                                                    </button>
                                                ))}
                                            </div>
                                        )}
                                    </>
                                )}
                                <p className="mt-1.5 text-[10.5px] text-slate-400">
                                    Pick a contact to resolve custom merge fields exactly as the live campaign would.
                                    Delivery still goes to the address above.
                                </p>
                            </div>

                            {missing.length > 0 && (
                                <div className="rounded-md border border-amber-200 bg-amber-50/60 px-3 py-2.5">
                                    <p className="text-[11px] leading-relaxed text-amber-800">
                                        The test contact has no{" "}
                                        <span className="font-medium">{missing.join(", ")}</span>, so{" "}
                                        {missing.length === 1 ? "that field" : "those fields"} will render empty. Real
                                        contacts need the matching import column filled.
                                    </p>
                                </div>
                            )}
                        </div>

                        <div className="flex items-center justify-end gap-2 border-t border-slate-200 px-3 py-2.5">
                            <button
                                type="button"
                                onClick={onClose}
                                disabled={busy}
                                className="h-7 rounded-md border border-slate-200 bg-white px-2.5 text-[12px] font-medium text-slate-700 transition-colors hover:border-slate-300 hover:text-slate-900 disabled:opacity-40"
                            >
                                Cancel
                            </button>
                            <button
                                type="button"
                                onClick={submit}
                                disabled={!canSend}
                                className="inline-flex h-7 items-center gap-1.5 rounded-md bg-sky-600 px-3 text-[12px] font-medium text-white transition-colors hover:bg-sky-700 disabled:opacity-40"
                            >
                                {busy ? (
                                    <Loader2Icon className="h-3 w-3 animate-spin" />
                                ) : (
                                    <SendIcon className="h-3 w-3" />
                                )}
                                Send test
                            </button>
                        </div>
                    </motion.div>
                </motion.div>
            )}
        </AnimatePresence>
    );
}
