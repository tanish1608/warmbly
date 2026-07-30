package wmail

import (
	"context"
	"errors"

	"github.com/warmbly/warmbly/internal/errx"
	"github.com/warmbly/warmbly/internal/models"
)

func (w *WMail) SyncGoogle(ctx context.Context) *errx.MailError {
	newHistoryID, err := w.GoogleData.Client.FetchHistory(ctx, w.GoogleData.LastHistoryID)
	if newHistoryID != 0 {
		// Advance the in-memory cursor, not just the persisted one. The sync loop
		// re-reads this field every pass and only ever gets the value the mailbox
		// was loaded with otherwise, so the cursor never moves for the life of the
		// process and no change is ever detected. Safe without a lock: one
		// sequential goroutine per mailbox drives StartSyncWorker.
		w.GoogleData.LastHistoryID = newHistoryID

		if err := w.NewHistoryID(newHistoryID); err != nil {
			w.CaptureError(err)
			return nil
		}

		return nil
	}
	if err != nil {
		var errMail *errx.MailError
		if errors.As(err, &errMail) {
			return errMail
		}

		w.CaptureError(err)

		return nil
	}

	return nil
}

func (w *WMail) NewHistoryID(historyID uint64) error {
	// UserID and EmailID must be set explicitly: onEvent only carries the account
	// id as a routing key and never fills the body, so omitting them published
	// zero UUIDs and the consumer's insert failed the email_history_ids user_id
	// foreign key on every retry.
	return w.onEvent(models.JobEventTypeHistoryIDUpdate, &models.JobEventHistoryIDUpdate{
		UserID:    w.UserID,
		EmailID:   w.ID,
		HistoryID: historyID,
	})
}
