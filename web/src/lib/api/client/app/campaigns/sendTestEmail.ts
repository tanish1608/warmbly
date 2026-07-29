import Request from "../../Request";

export interface SendTestEmailInput {
    // Which step to preview. Omitted means the campaign's first step.
    step_id?: string;
    // Mailbox the test is sent from; must be one of the campaign's senders.
    account_id: string;
    recipient: string;
}

// POST /campaigns/:id/test-email — renders the step against a synthetic
// contact (Test Recipient / Test Company) and sends it with a "[TEST]"
// subject prefix. Merge fields the synthetic contact does not carry render
// empty, which is the point: it shows what recipients would actually get.
export default async function sendTestEmail(campaignId: string, input: SendTestEmailInput): Promise<void> {
    await Request<void>({
        method: "POST",
        url: `/campaigns/${campaignId}/test-email`,
        data: input,
        authorization: true,
    });
}
