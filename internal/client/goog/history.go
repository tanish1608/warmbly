package goog

import (
	"context"

	"google.golang.org/api/googleapi"
)

func (c *Client) FetchHistory(ctx context.Context, lastHistoryID uint64) (uint64, error) {
	// A zero cursor means the mailbox has never synced. Gmail rejects
	// startHistoryId=0 with 404, and the caller only persists a cursor when this
	// returns one, so passing 0 through would 404 on every pass forever and the
	// mailbox would never sync at all. Anchor on the mailbox's present state.
	if lastHistoryID == 0 {
		return c.currentHistoryID(ctx)
	}

	call := c.srv.Users.History.List("me").MaxResults(500).StartHistoryId(lastHistoryID) // It does not include the record that has that exact HistoryID

	var newLastHistoryID uint64

	for {
		resp, err := call.Context(ctx).Do()
		if err != nil {
			// 404 means the cursor predates Gmail's history retention. The
			// documented recovery is a full resync, so re-anchor on the current
			// historyId instead of failing this pass (and every later one).
			if gerr, ok := err.(*googleapi.Error); ok && gerr.Code == 404 {
				return c.currentHistoryID(ctx)
			}
			return newLastHistoryID, HandleError(err)
		}

		for _, h := range resp.History {
			for _, m := range h.MessagesAdded {
				// History entries carry only id/threadId/labelIds — no envelope,
				// headers, or body — so hydrate the full message before mapping.
				// A 404 means the message was deleted between the history event
				// and now; skip it rather than failing the whole sync.
				full, ferr := c.srv.Users.Messages.Get("me", m.Message.Id).Format("full").Context(ctx).Do()
				if ferr != nil {
					if gerr, ok := ferr.(*googleapi.Error); ok && gerr.Code == 404 {
						continue
					}
					return newLastHistoryID, HandleError(ferr)
				}

				msg := GmailMessageToEmailData(full)
				if err := c.OnMessageAdd(ctx, msg); err != nil {
					return newLastHistoryID, err
				}
			}
			for _, m := range h.MessagesDeleted {
				if err := c.OnMessageRemove(ctx, m.Message.Id); err != nil {
					return newLastHistoryID, err
				}
			}
			for _, m := range h.LabelsAdded {
				if err := c.OnLabelAdd(ctx, m.Message.Id, m.LabelIds); err != nil {
					return newLastHistoryID, err
				}
			}
			for _, m := range h.LabelsRemoved {
				if err := c.OnLabelRemove(ctx, m.Message.Id, m.LabelIds); err != nil {
					return newLastHistoryID, err
				}
			}
		}
		newLastHistoryID = resp.HistoryId
		if resp.NextPageToken == "" {
			break
		}
		call.PageToken(resp.NextPageToken)
	}

	return newLastHistoryID, nil
}

// currentHistoryID anchors the sync cursor on the mailbox's present state. Mail
// already in the mailbox is not replayed: the cursor exists to detect changes
// from this point on, which is what reply tracking needs.
func (c *Client) currentHistoryID(ctx context.Context) (uint64, error) {
	prof, err := c.srv.Users.GetProfile("me").Context(ctx).Do()
	if err != nil {
		return 0, HandleError(err)
	}
	return prof.HistoryId, nil
}
